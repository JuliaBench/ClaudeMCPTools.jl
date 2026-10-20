@testset "Sessioned bash with an interactive shell" begin
    # `bash -i` on a pipe echoes each input line, as BinaryBuilder's debug shell does
    manager = SessionManager(_ -> (`bash --norc --noprofile -i`, Dict{String,Any}());
                             ready_timeout_s=30.0, log=_ -> nothing)
    session = start_session(manager, Dict{String,Any}())
    try
        output, exit_code, died, timed_out = exec_command(manager, session, "echo hello; false"; timeout_ms=10_000)
        @test exit_code == 1
        @test !timed_out
        @test output == "hello"

        output, exit_code, _, timed_out = exec_command(manager, session, "echo again"; timeout_ms=10_000)
        @test exit_code == 0
        @test !timed_out
        @test output == "again"
    finally
        stop_session(manager, session.id)
    end
end
