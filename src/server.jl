"""
MCP Server implementation
"""

"""
    handle_request(server::MCPServer, request::Dict)

Process an MCP request and return a response.
"""
function handle_request(server::MCPServer, request::Dict)
    method = get(request, "method", "")
    id = get(request, "id", nothing)
    params = get(request, "params", Dict())
    
    try
        response = if method == "initialize"
            handle_initialize(server, params)
        elseif method == "tools/list"
            handle_tools_list(server, params)
        elseif method == "tools/call"
            handle_tools_call(server, params)
        else
            Dict("error" => Dict(
                "code" => -32601,
                "message" => "Method not found: $method"
            ))
        end
        
        # Add JSON-RPC fields
        result = Dict{String,Any}("jsonrpc" => "2.0")
        if id !== nothing
            result["id"] = id
        end
        
        if haskey(response, "error")
            result["error"] = response["error"]
        else
            result["result"] = response
        end
        
        return result
        
    catch e
        error_response = Dict{String,Any}(
            "jsonrpc" => "2.0",
            "error" => Dict(
                "code" => -32603,
                "message" => "Internal error: $(string(e))"
            )
        )
        if id !== nothing
            error_response["id"] = id
        end
        return error_response
    end
end

function handle_initialize(server::MCPServer, params::Dict)
    return Dict(
        "protocolVersion" => "2024-11-05",
        "serverInfo" => server.metadata,
        "capabilities" => Dict(
            "tools" => Dict("listChanged" => false)
        )
    )
end

function handle_tools_list(server::MCPServer, params::Dict)
    tools = [tool_schema(tool) for (name, tool) in server.tools]
    return Dict("tools" => tools)
end

function handle_tools_call(server::MCPServer, params::Dict)
    tool_name = get(params, "name", nothing)
    tool_args = get(params, "arguments", Dict())
    
    if tool_name === nothing
        return Dict("error" => Dict(
            "code" => -32602,
            "message" => "Tool name is required"
        ))
    end
    
    tool = get(server.tools, tool_name, nothing)
    if tool === nothing
        return Dict("error" => Dict(
            "code" => -32602,
            "message" => "Unknown tool: $tool_name"
        ))
    end
    
    # Execute the tool and return the result
    return execute(tool, tool_args)
end

"""
    run_stdio_server(server::MCPServer; verbose::Bool=false)

Run the MCP server in stdio mode, reading JSON-RPC from stdin and writing to stdout.
"""
function run_stdio_server(server::MCPServer; verbose::Bool=false)
    if verbose
        @info "Starting MCP server in stdio mode"
    end
    
    # Read JSON-RPC messages from stdin
    for line in eachline(stdin)
        if isempty(strip(line))
            continue
        end
        
        try
            request = JSON.parse(line)
            response = handle_request(server, request)
            println(stdout, JSON.json(response))
            flush(stdout)
        catch e
            if verbose
                @error "Error processing request" exception=e
            end
            error_response = Dict{String,Any}(
                "jsonrpc" => "2.0",
                "error" => Dict(
                    "code" => -32700,
                    "message" => "Parse error"
                )
            )
            println(stdout, JSON.json(error_response))
            flush(stdout)
        end
    end
end