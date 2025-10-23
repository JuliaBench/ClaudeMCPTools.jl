"""
MCP Server implementation
"""

"""
    handle_request(server::MCPServer, request::AbstractDict)

Process an MCP request and return a response.
"""
function handle_request(server::MCPServer, request::AbstractDict)
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

function handle_initialize(server::MCPServer, params::AbstractDict)
    return Dict(
        "protocolVersion" => "2024-11-05",
        "serverInfo" => server.metadata,
        "capabilities" => Dict(
            "tools" => Dict("listChanged" => false)
        )
    )
end

function handle_tools_list(server::MCPServer, params::AbstractDict)
    tools = [tool_schema(tool) for (name, tool) in server.tools]
    return Dict("tools" => tools)
end

function handle_tools_call(server::MCPServer, params::AbstractDict)
    tool_name = get(params, "name", nothing)
    tool_args = get(params, "arguments", Dict())
    
    if tool_name === nothing
        return Dict("error" => Dict(
            "code" => -32602,
            "message" => "Tool name is required"
        ))
    end
    
    # Map API tool names back to MCP tool names if needed
    # This handles clients that use the Anthropic API tool naming conventions
    tool_name_mapping = Dict(
        "str_replace_based_edit_tool" => "str_replace_editor",
        # bash stays as bash
    )
    actual_tool_name = get(tool_name_mapping, tool_name, tool_name)
    
    tool = get(server.tools, actual_tool_name, nothing)
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
    run_unix_socket_server(server::MCPServer, socket_path::String; verbose::Bool=false, cleanup::Bool=true)

Run the MCP server on a Unix domain socket.
"""
function run_unix_socket_server(server::MCPServer, socket_path::String; verbose::Bool=false, cleanup::Bool=true)
    
    # Clean up existing socket if it exists
    if cleanup && isfile(socket_path)
        rm(socket_path)
    end
    
    # Create the Unix socket
    socket = listen(socket_path)
    
    if verbose
        @info "MCP server listening on Unix socket: $socket_path"
    end
    
    try
        while true
            # Accept a connection
            client = accept(socket)
            
            if verbose
                @info "Client connected to Unix socket"
            end
            
            # Handle the client in a task
            @async try
                while isopen(client)
                    # Read a line from the client
                    line = readline(client)
                    
                    if isempty(line)
                        continue
                    end
                    
                    # Parse and handle the request
                    try
                        request = JSON.parse(line)

                        # Log incoming message to stderr in verbose mode
                        if verbose
                            println(stderr, "Incoming message: ", JSON.json(request, 2))
                            flush(stderr)
                        end

                        response = handle_request(server, request)
                        
                        # Log outgoing response to stderr in verbose mode
                        if verbose
                            println(stderr, "Outgoing response: ", JSON.json(response, 2))
                            flush(stderr)
                        end
                        
                        println(client, JSON.json(response))
                        flush(client)
                    catch e
                        if verbose
                            @error "Error handling request" exception=e
                        end
                        error_response = Dict(
                            "jsonrpc" => "2.0",
                            "error" => Dict(
                                "code" => -32700,
                                "message" => "Parse error: $(string(e))"
                            )
                        )
                        println(client, JSON.json(error_response))
                        flush(client)
                    end
                end
            catch e
                if verbose && !(e isa EOFError)
                    @error "Client connection error" exception=e
                end
            finally
                close(client)
                if verbose
                    @info "Client disconnected from Unix socket"
                end
            end
        end
    finally
        close(socket)
        if cleanup && isfile(socket_path)
            rm(socket_path)
        end
    end
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

            # Log incoming message to stderr in verbose mode
            if verbose
                println(stderr, "Incoming message: ", JSON.json(request, 2))
                flush(stderr)
            end

            response = handle_request(server, request)
            
            # Log outgoing response to stderr in verbose mode
            if verbose
                println(stderr, "Outgoing response: ", JSON.json(response, 2))
                flush(stderr)
            end
            
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