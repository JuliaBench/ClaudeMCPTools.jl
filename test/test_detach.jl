@testset "Detached subprocesses" begin
    using ClaudeMCPTools: execute

    mktempdir() do tmpdir
        pidfile = joinpath(tmpdir, "pid")
        tool = BashTool(working_dir=tmpdir)
        result = execute(tool, Dict("command" => "sleep 300 & echo \$! > $pidfile; wait", "timeout" => 1))
        @test result["isError"]
        pid = parse(Int, readchomp(pidfile))
        sleep(0.5)
        # kill(pid, 0) fails once the grandchild is gone
        @test ccall(:kill, Cint, (Cint, Cint), pid, 0) != 0
    end

    manager = SessionManager(_ -> (`bash --norc --noprofile`, Dict{String,Any}());
                             ready_timeout_s=30.0, log=_ -> nothing)
    session = start_session(manager, Dict{String,Any}())
    try
        # Only meaningful when the tests themselves run under a TTY
        _, exit_code, _, _ = exec_command(manager, session, ": </dev/tty"; timeout_ms=10_000)
        @test exit_code != 0
    finally
        stop_session(manager, session.id)
    end
end
