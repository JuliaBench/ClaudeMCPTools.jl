using ClaudeMCPTools
using Test
using JSON

@testset "ClaudeMCPTools.jl" begin
    include("test_bash.jl")
    include("test_bash_timeout.jl")
    include("test_sessioned_bash.jl")
    include("test_str_replace_editor.jl")
    include("test_view_range.jl")
    include("test_server.jl")

    @testset "No method ambiguities" begin
        @test isempty(Test.detect_ambiguities(ClaudeMCPTools))
    end
end
