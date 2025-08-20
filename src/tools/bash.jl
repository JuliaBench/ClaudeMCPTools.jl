"""
Bash command execution tool for MCP
"""

mutable struct BashTool <: MCPTool
    working_dir::String
    env::Dict{String, String}
    
    function BashTool(; working_dir::String=pwd(), env::Dict{String, String}=Dict{String, String}())
        new(working_dir, env)
    end
end

function tool_schema(::BashTool)
    return Dict(
        "name" => "bash",
        "description" => "Execute bash commands in a shell",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "command" => Dict(
                    "type" => "string",
                    "description" => "The bash command to execute"
                )
            ),
            "required" => ["command"]
        )
    )
end

function execute(tool::BashTool, params::Dict)
    command = get(params, "command", nothing)
    
    if command === nothing
        return Dict("content" => [Dict(
            "type" => "text",
            "text" => "Error: No command provided"
        )])
    end
    
    try
        # Use Cmd with ignorestatus to capture all output regardless of exit code
        cmd = Cmd(`sh -c $command`, ignorestatus=true, dir=tool.working_dir)
        
        # Merge tool environment with command environment
        if !isempty(tool.env)
            cmd = setenv(cmd, merge(ENV, tool.env))
        end
        
        # Create pipes for stdout and stderr
        stdout_buf = IOBuffer()
        stderr_buf = IOBuffer()
        
        # Run the command and capture outputs
        proc = run(pipeline(cmd, stdout=stdout_buf, stderr=stderr_buf))
        
        # Get the outputs
        stdout_str = String(take!(stdout_buf))
        stderr_str = String(take!(stderr_buf))
        exit_code = proc.exitcode
        
        # Format the response
        response_parts = String[]
        
        # Add stdout if not empty
        if !isempty(stdout_str)
            push!(response_parts, stdout_str)
        end
        
        # Add stderr if not empty (prefix it to distinguish)
        if !isempty(stderr_str)
            if !isempty(response_parts)
                push!(response_parts, "\n--- stderr ---\n")
            end
            push!(response_parts, stderr_str)
        end
        
        # Add exit code if non-zero
        if exit_code != 0
            if !isempty(response_parts)
                push!(response_parts, "\n")
            end
            push!(response_parts, "Exit code: $exit_code")
        end
        
        # If no output at all, indicate success
        if isempty(response_parts)
            push!(response_parts, "Command completed successfully (no output)")
        end
        
        result_text = join(response_parts)
        
        return Dict("content" => [Dict(
            "type" => "text",
            "text" => result_text
        )])
        
    catch e
        error_msg = "Failed to execute command: " * string(e)
        return Dict("content" => [Dict(
            "type" => "text",
            "text" => error_msg
        )])
    end
end