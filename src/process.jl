"""
    detached(cmd)

Run `cmd` in a new session (`setsid`), detached from the parent's controlling
terminal. MCP servers usually run under an interactive process such as Claude
Code in a TTY; without this, descendants can open `/dev/tty` and write escape
sequences (focus reporting, raw mode, ...) straight to the user's terminal,
leaving it broken after the session. See JuliaContainerization/Sandbox.jl#159.

The child becomes the leader of its own process group, which `ProcessGroup`
and `kill_group` rely on. Only a plain `Cmd` can be detached; pipelines are a
`MethodError` rather than silently left attached to the terminal.
"""
detached(cmd::Cmd) = Cmd(cmd; detach=true)

"""
    ProcessGroup(process; sudo_uid=nothing)

The process group led by `process`, which must have been started from a
`detached` command. The group id is recorded at spawn time: `getpid(process)`
throws once the leader has exited, but background jobs in the group may still
be running. POSIX does not reuse a pid while a process group with that id
exists, so the recorded id cannot name an unrelated group while any member of
ours is alive. Once the group is seen empty it is marked `dead` and never
signalled again, because by then the id may belong to someone else. Tracked
groups are checked every `PRUNE_INTERVAL_S` seconds, so that window is short.

Set `sudo_uid` when the leader is `sudo -u #uid ...`. A non-root server may
not signal processes owned by that uid, so `kill_group` also signals the group
through `sudo`.
"""
mutable struct ProcessGroup
    const pgid::Cint
    const process::Base.Process
    const sudo_uid::Union{Int,Nothing}
    # An empty group can never gain members again, so this only goes false -> true
    @atomic dead::Bool
end

function ProcessGroup(process::Base.Process; sudo_uid::Union{Int,Nothing}=nothing)
    # getpid only fails if the leader already exited and was reaped. Record 0,
    # which every function below treats as "no group" (never kill(0)/kill(-1)).
    pgid = try
        Cint(getpid(process))
    catch
        Cint(0)
    end
    return ProcessGroup(pgid, process, sudo_uid, false)
end

_has_group(g::ProcessGroup) = !Sys.iswindows() && g.pgid > 1

"""
    group_alive(g)

Whether any process in the group still exists (including ones this process
may not signal). The first `false` marks the group dead for good.
"""
function group_alive(g::ProcessGroup)
    _has_group(g) || return process_running(g.process)
    (@atomic g.dead) && return false
    ret = ccall(:kill, Cint, (Cint, Cint), -g.pgid, 0)
    alive = ret == 0 || Libc.errno() == Libc.EPERM
    alive || @atomic g.dead = true
    return alive
end

function _can_signal_uid(uid::Integer)
    euid = ccall(:geteuid, Cuint, ())
    return euid == 0 || euid == uid
end

_signal_name(signum::Integer) =
    signum == Base.SIGKILL ? "KILL" : signum == Base.SIGTERM ? "TERM" : string(signum)

"""
    kill_group(g, signum) -> Bool

Signal every process in the group `g`, so grandchildren are not left running.
Returns whether anything was signalled. Never throws. A group already seen
empty is not signalled, since its id may have been reused.

If the group cannot be signalled (e.g. `EPERM`) and the leader is still
running, the leader is signalled directly. Groups started through `sudo` are
also signalled as the target user. On Windows only the process itself is
signalled.
"""
function kill_group(g::ProcessGroup, signum::Integer)
    signalled = false
    if _has_group(g) && group_alive(g)
        signalled = ccall(:kill, Cint, (Cint, Cint), -g.pgid, signum) == 0
        if g.sudo_uid !== nothing && !_can_signal_uid(g.sudo_uid)
            # Members running as the target uid are out of our reach; sudo
            # itself is not, but it does not relay SIGKILL.
            cmd = `sudo -n -u "#$(g.sudo_uid)" kill -s $(_signal_name(signum)) -- -$(g.pgid)`
            try
                signalled |= success(pipeline(cmd, stdin=devnull, stdout=devnull, stderr=devnull))
            catch
            end
        end
    end
    if !signalled && process_running(g.process)
        try
            kill(g.process, signum)
            signalled = true
        catch
        end
    end
    return signalled
end

"""
    terminate_groups(groups; grace_s=1.0)

Send SIGTERM to each group, wait up to `grace_s` seconds for them to exit,
then SIGKILL whatever is left.
"""
function terminate_groups(groups; grace_s::Real=1.0)
    alive = filter(group_alive, collect(groups))
    isempty(alive) && return nothing
    foreach(g -> kill_group(g, Base.SIGTERM), alive)
    deadline = time() + grace_s
    while !isempty(alive) && time() < deadline
        sleep(0.02)
        filter!(group_alive, alive)
    end
    foreach(g -> kill_group(g, Base.SIGKILL), alive)
    return nothing
end

# Groups that may still have running members. Detached children no longer get
# SIGHUP when the user's terminal closes, so these are killed when the server
# exits instead (see `__init__`). A server killed with SIGKILL cannot clean up.
const TRACKED_GROUPS = Dict{Cint,ProcessGroup}()
const TRACKED_GROUPS_LOCK = ReentrantLock()

# How often tracked groups are checked, so an empty group is marked dead
# before its id can be reused. Pid reuse needs the whole pid range to wrap.
const PRUNE_INTERVAL_S = 5.0
const PRUNE_TIMER = Ref{Union{Timer,Nothing}}(nothing)

"""
Forget tracked groups that have died, marking them dead. Stops the pruning
timer once nothing is tracked.
"""
function prune_tracked_groups!()
    lock(TRACKED_GROUPS_LOCK) do
        filter!(p -> group_alive(p.second), TRACKED_GROUPS)
        if isempty(TRACKED_GROUPS) && PRUNE_TIMER[] !== nothing
            close(PRUNE_TIMER[])
            PRUNE_TIMER[] = nothing
        end
    end
    return nothing
end

function track!(g::ProcessGroup)
    _has_group(g) || return g
    lock(TRACKED_GROUPS_LOCK) do
        filter!(p -> group_alive(p.second), TRACKED_GROUPS)
        TRACKED_GROUPS[g.pgid] = g
        if PRUNE_TIMER[] === nothing
            PRUNE_TIMER[] = Timer(_ -> prune_tracked_groups!(), PRUNE_INTERVAL_S; interval=PRUNE_INTERVAL_S)
        end
    end
    return g
end

function untrack!(g::ProcessGroup)
    lock(TRACKED_GROUPS_LOCK) do
        get(TRACKED_GROUPS, g.pgid, nothing) === g && delete!(TRACKED_GROUPS, g.pgid)
    end
    return nothing
end

"""
Stop tracking `g` unless members (e.g. background jobs) are still running.
"""
function retire!(g::ProcessGroup)
    group_alive(g) || untrack!(g)
    return nothing
end

"""
    kill_tracked_groups(; grace_s=1.0)

Terminate every tracked process group. Registered with `atexit`.
"""
function kill_tracked_groups(; grace_s::Real=1.0)
    groups = lock(TRACKED_GROUPS_LOCK) do
        gs = collect(values(TRACKED_GROUPS))
        empty!(TRACKED_GROUPS)
        PRUNE_TIMER[] === nothing || close(PRUNE_TIMER[])
        PRUNE_TIMER[] = nothing
        gs
    end
    terminate_groups(groups; grace_s)
    return nothing
end

"""
    start_reader(pipe) -> (buffer, task)

Copy everything read from `pipe` into a fresh `IOBuffer` on a background task.
Use `finish_reader!` to get the contents.
"""
function start_reader(pipe::Pipe)
    buf = IOBuffer()
    task = @async try
        while !eof(pipe)
            write(buf, readavailable(pipe))
        end
    catch
        # The pipe was closed under us by `finish_reader!`
    end
    return buf, task
end

"""
    finish_reader!(pipe, buffer, task) -> String

Close `pipe`, wait for its reader task to stop, and return what it read. The
task has finished writing before the buffer is read.
"""
function finish_reader!(pipe::Pipe, buf::IOBuffer, task::Task)
    close(pipe)
    wait(task)
    return String(take!(buf))
end
