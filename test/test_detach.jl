@testset "Detached subprocesses" begin
    using ClaudeMCPTools: execute, kill_tracked_groups, TRACKED_GROUPS

    # A killed process can linger as a zombie until it is reaped, and kill(pid, 0)
    # still succeeds for it, so look at its state instead.
    function pid_gone(pid)
        stat = strip(readchomp(ignorestatus(`ps -o stat= -p $pid`)))
        return isempty(stat) || startswith(stat, "Z")
    end
    function wait_gone(pid; timeout=10.0)
        deadline = time() + timeout
        while time() < deadline
            pid_gone(pid) && return true
            sleep(0.05)
        end
        return pid_gone(pid)
    end
    text(result) = result["content"][1]["text"]
    our_pgid = ccall(:getpgrp, Cint, ())

    mktempdir() do tmpdir
        tool = BashTool(working_dir=tmpdir)

        @testset "BashTool runs in its own process group" begin
            # Holds without a TTY, unlike checks on /dev/tty
            pid, pgid = parse.(Int, split(text(execute(tool, Dict("command" => "echo \$\$ \$(ps -o pgid= -p \$\$)")))))
            @test pgid == pid
            @test pgid != our_pgid
        end

        @testset "Timeout kills grandchildren" begin
            pidfile = joinpath(tmpdir, "pid")
            result = execute(tool, Dict("command" => "sleep 300 & echo \$! > $pidfile; wait", "timeout" => 1))
            @test result["isError"]
            @test occursin("timed out", text(result))
            @test wait_gone(parse(Int, readchomp(pidfile)))
        end

        @testset "Output written just before exit is not lost" begin
            result = execute(tool, Dict("command" => "head -c 30000 /dev/zero | tr '\\0' a; printf b >&2"))
            @test text(result) == "a"^30000 * "\n--- stderr ---\nb"
        end

        @testset "Background job holding stdout does not block the call" begin
            t = @elapsed result = execute(tool, Dict("command" => "sleep 300 & echo \$!; echo done"))
            @test t < 10
            pid_str, done = split(text(result))
            @test done == "done"
            pid = parse(Int, pid_str)
            @test !pid_gone(pid)
            # Still tracked, so it is killed when the server exits
            job_pgid = parse(Int, strip(readchomp(`ps -o pgid= -p $pid`)))
            @test haskey(TRACKED_GROUPS, job_pgid)
            kill_tracked_groups()
            @test wait_gone(pid)
        end

        if Sys.islinux() && ccall(:geteuid, Cuint, ()) != 0 && success(`sudo -n true`)
            @testset "Timeout kills grandchildren running as another uid" begin
                chmod(tmpdir, 0o777)
                pidfile = joinpath(tmpdir, "uidpid")
                uidtool = BashTool(working_dir=tmpdir, uid=65534)
                result = execute(uidtool, Dict("command" => "sleep 300 & echo \$! > $pidfile; wait", "timeout" => 2))
                @test result["isError"]
                @test wait_gone(parse(Int, readchomp(pidfile)))
            end
        end
    end

    manager = SessionManager(_ -> (`bash --norc --noprofile`, Dict{String,Any}());
                             ready_timeout_s=30.0, log=_ -> nothing)

    @testset "Session runs in its own process group" begin
        session = start_session(manager, Dict{String,Any}())
        try
            out, exit_code, _, _ = exec_command(manager, session, "echo \$\$ \$(ps -o pgid= -p \$\$)"; timeout_ms=10_000)
            @test exit_code == 0
            pid, pgid = parse.(Int, split(out))
            @test pgid == pid
            @test pgid != our_pgid
            # Also only meaningful when the tests themselves run under a TTY
            _, exit_code, _, _ = exec_command(manager, session, ": </dev/tty"; timeout_ms=10_000)
            @test exit_code != 0
        finally
            stop_session(manager, session.id)
        end
    end

    @testset "stop_session kills background jobs" begin
        session = start_session(manager, Dict{String,Any}())
        out, _, _, _ = exec_command(manager, session, "sleep 300 >/dev/null 2>&1 & echo \$!"; timeout_ms=10_000)
        pid = parse(Int, out)
        @test !pid_gone(pid)
        @test stop_session(manager, session.id)
        @test wait_gone(pid)
    end

    @testset "Failed startup does not leak the session" begin
        mktempdir() do tmpdir
            pidfile = joinpath(tmpdir, "pid")
            # Never answers the readiness probe
            hung = SessionManager(_ -> (`sh -c "sleep 300 >/dev/null 2>&1 & echo \$! > $pidfile; exec cat >/dev/null"`, Dict{String,Any}());
                                  ready_timeout_s=2.0, log=_ -> nothing)
            @test_throws ErrorException start_session(hung, Dict{String,Any}())
            @test isempty(hung.sessions)
            @test wait_gone(parse(Int, readchomp(pidfile)))
        end
    end
end
