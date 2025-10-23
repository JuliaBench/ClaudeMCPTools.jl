@testset "MCPServer" begin
    @testset "Server creation" begin
        server = MCPServer(name="TestServer", version="1.0.0")
        @test server.metadata["name"] == "TestServer"
        @test server.metadata["version"] == "1.0.0"
        @test isempty(server.tools)
    end
    
    @testset "Tool registration" begin
        server = MCPServer()
        bash = BashTool()
        editor = StrReplaceEditorTool()
        
        register_tool!(server, "bash", bash)
        register_tool!(server, "editor", editor)
        
        @test length(server.tools) == 2
        @test server.tools["bash"] === bash
        @test server.tools["editor"] === editor
    end
    
    @testset "Initialize request" begin
        server = MCPServer(name="TestServer", version="1.0.0")
        
        request = Dict(
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "initialize",
            "params" => Dict()
        )
        
        response = handle_request(server, request)
        
        @test response["jsonrpc"] == "2.0"
        @test response["id"] == 1
        @test haskey(response, "result")
        @test response["result"]["protocolVersion"] == "2024-11-05"
        @test response["result"]["serverInfo"]["name"] == "TestServer"
        @test response["result"]["serverInfo"]["version"] == "1.0.0"
        @test haskey(response["result"], "capabilities")
    end
    
    @testset "Tools list request" begin
        server = MCPServer()
        register_tool!(server, "bash", BashTool())
        register_tool!(server, "editor", StrReplaceEditorTool())
        
        request = Dict(
            "jsonrpc" => "2.0",
            "id" => 2,
            "method" => "tools/list",
            "params" => Dict()
        )
        
        response = handle_request(server, request)
        
        @test response["jsonrpc"] == "2.0"
        @test response["id"] == 2
        @test haskey(response, "result")
        @test haskey(response["result"], "tools")
        @test length(response["result"]["tools"]) == 2
        
        tool_names = [tool["name"] for tool in response["result"]["tools"]]
        @test "bash" in tool_names
        @test "str_replace_editor" in tool_names
    end
    
    @testset "Tool call request" begin
        server = MCPServer()
        register_tool!(server, "bash", BashTool())
        
        request = Dict(
            "jsonrpc" => "2.0",
            "id" => 3,
            "method" => "tools/call",
            "params" => Dict(
                "name" => "bash",
                "arguments" => Dict("command" => "echo 'test'")
            )
        )
        
        response = handle_request(server, request)
        
        @test response["jsonrpc"] == "2.0"
        @test response["id"] == 3
        @test haskey(response, "result")
        @test haskey(response["result"], "content")
        @test response["result"]["content"][1]["type"] == "text"
        @test occursin("test", response["result"]["content"][1]["text"])
    end
    
    @testset "Error handling" begin
        server = MCPServer()
        
        # Unknown method
        request = Dict(
            "jsonrpc" => "2.0",
            "id" => 4,
            "method" => "unknown/method",
            "params" => Dict()
        )
        
        response = handle_request(server, request)
        @test haskey(response, "error")
        @test response["error"]["code"] == -32601
        @test occursin("not found", response["error"]["message"])
        
        # Unknown tool
        request = Dict(
            "jsonrpc" => "2.0",
            "id" => 5,
            "method" => "tools/call",
            "params" => Dict(
                "name" => "nonexistent",
                "arguments" => Dict()
            )
        )
        
        response = handle_request(server, request)
        @test haskey(response, "error")
        @test occursin("Unknown tool", response["error"]["message"])
        
        # Missing tool name
        request = Dict(
            "jsonrpc" => "2.0",
            "id" => 6,
            "method" => "tools/call",
            "params" => Dict("arguments" => Dict())
        )
        
        response = handle_request(server, request)
        @test haskey(response, "error")
        @test occursin("required", response["error"]["message"])
    end
    
    @testset "Request without ID (notification)" begin
        server = MCPServer()
        
        request = Dict(
            "jsonrpc" => "2.0",
            "method" => "initialize",
            "params" => Dict()
        )
        
        response = handle_request(server, request)
        
        @test response["jsonrpc"] == "2.0"
        @test !haskey(response, "id")  # No ID for notifications
        @test haskey(response, "result")
    end
end