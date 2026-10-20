"""
    detached(cmd)

Run `cmd` in a new session (`setsid`), detached from the parent's controlling
terminal. MCP servers usually run under an interactive process such as Claude
Code in a TTY; without this, descendants can open `/dev/tty` and write escape
sequences (focus reporting, raw mode, ...) straight to the user's terminal,
leaving it broken after the session. See JuliaContainerization/Sandbox.jl#159.

Only a plain `Cmd` carries the `detach` flag; pipelines and other
`AbstractCmd`s are returned unchanged.
"""
detached(cmd::Cmd) = Cmd(cmd; detach=true)
detached(cmd::Base.AbstractCmd) = cmd

"""
    kill_group(process, signum)

Signal the process group led by `process`, which `detached` makes it the
leader of, so grandchildren are not left running. Falls back to signalling
`process` alone on Windows.
"""
function kill_group(process::Base.Process, signum::Integer)
    Sys.iswindows() && return kill(process, signum)
    ccall(:kill, Cint, (Cint, Cint), -getpid(process), signum)
    return nothing
end
