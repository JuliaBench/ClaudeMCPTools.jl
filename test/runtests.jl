using ClaudeMCPTools
using Test
using JSON

@testset "ClaudeMCPTools.jl" begin
    include("test_bash.jl")
    include("test_str_replace_editor.jl")
    include("test_server.jl")
end