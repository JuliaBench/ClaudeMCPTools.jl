"""
Bash command execution tool for MCP
"""

# Helper function to get user's home directory using getpwuid
function get_user_home(uid::Int)
    # Use Libc.getpwuid to get user info - it returns a Libc.Passwd object or nothing
    # Convert to UInt as getpwuid expects unsigned
    passwd_info = Libc.getpwuid(UInt(uid))
    
    if passwd_info === nothing
        # Failed to get user info, return nothing
        return nothing
    end
    
    # Libc.getpwuid returns a Libc.Passwd object with homedir field already as a string
    return passwd_info.homedir
end

mutable struct BashTool <: MCPTool
    working_dir::String
    env::Dict{String, String}
    uid::Union{Int, Nothing}
    
    function BashTool(; working_dir::String=pwd(), env::Dict{String, String}=Dict{String, String}(), uid::Union{Int, Nothing}=nothing)
        new(working_dir, env, uid)
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
                ),
                "timeout" => Dict(
                    "type" => "integer",
                    "description" => "Maximum execution time in seconds (default: 120)",
                    "minimum" => 1,
                    "maximum" => 600
                )
            ),
            "required" => ["command"]
        )
    )
end

function execute(tool::BashTool, params::AbstractDict)
    command = get(params, "command", nothing)
    timeout_seconds = get(params, "timeout", 120)  # Default 120 seconds
    
    if command === nothing
        return create_content_response("Error: No command provided", is_error=true)
    end
    
    # Validate timeout
    if timeout_seconds < 1 || timeout_seconds > 600
        return create_content_response("Error: Timeout must be between 1 and 600 seconds", is_error=true)
    end
    
    try
        # Build the command - if uid is specified, use sudo to run as that user
        if tool.uid !== nothing
            # Get current PATH to restore it inside sudo
            current_path = get(ENV, "PATH", "")
            
            # Get target user's home directory
            user_home = get_user_home(tool.uid)
            
            # Build the sudo command
            # -E: preserve environment variables (but PATH is still reset by sudo)
            # -u #uid: run as the specified UID (# prefix tells sudo it's a UID not username)
            # env PATH=...: explicitly restore PATH inside sudo (sudo has special handling for PATH)
            # sh -c: use shell to run the command
            cmd = Cmd(`sudo -E -u "#$(tool.uid)" env PATH=$current_path sh -c $command`, ignorestatus=true, dir=tool.working_dir)
            
            # Add HOME environment variable via addenv (sudo -E preserves it)
            if user_home !== nothing
                cmd = addenv(cmd, "HOME"=>user_home)
            end
        else
            # Use Cmd with ignorestatus to capture all output regardless of exit code
            cmd = Cmd(`sh -c $command`, ignorestatus=true, dir=tool.working_dir)
        end
        
        # Merge tool environment with command environment
        if !isempty(tool.env)
            cmd = addenv(cmd, tool.env)
        end
        
        # Create pipes for stdout and stderr
        stdout_buf = IOBuffer()
        stderr_buf = IOBuffer()
        
        # Start the process without waiting for it to complete
        process = open(pipeline(cmd, stdout=stdout_buf, stderr=stderr_buf))
        
        # Wait for completion with timeout
        timed_out = false
        start_time = time()
        
        while process_running(process)
            if time() - start_time > timeout_seconds
                timed_out = true
                # Kill the process forcefully
                kill(process, Base.SIGKILL)
                # Give it a brief moment to terminate
                sleep(0.1)
                # If still running, force terminate
                if process_running(process)
                    try
                        # Force kill using SIGKILL
                        kill(process, Base.SIGKILL)
                    catch
                        # Process might already be dead
                    end
                end
                break
            end
            sleep(0.1)  # Check every 100ms
        end
        
        # Don't wait for process if we killed it - just return timeout error
        if timed_out
            return create_content_response(
                "Error: Command timed out after $timeout_seconds seconds", 
                is_error=true
            )
        end
        
        # Get the process result
        proc = process
        
        # Get the outputs
        stdout_str = String(take!(stdout_buf))
        stderr_str = String(take!(stderr_buf))
        exit_code = proc.exitcode

        # Truncate output if needed (30KB = 30720 bytes)
        max_output_bytes = 30720
        truncated = false

        # Check and truncate stdout
        if sizeof(stdout_str) > max_output_bytes
            stdout_str = String(codeunits(stdout_str)[1:max_output_bytes])
            truncated = true
        end

        # Check and truncate stderr (allow some space for both)
        stderr_max = max(1024, max_output_bytes - sizeof(stdout_str))  # At least 1KB for stderr
        if sizeof(stderr_str) > stderr_max
            stderr_str = String(codeunits(stderr_str)[1:stderr_max])
            truncated = true
        end

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

        # Add truncation notice if output was truncated
        if truncated
            if !isempty(response_parts)
                push!(response_parts, "\n")
            end
            push!(response_parts, "--- Output truncated (exceeded 30KB limit) ---")
        end

        # Add exit code if non-zero
        if exit_code != 0
            if !isempty(response_parts)
                push!(response_parts, "\n")
            end
            push!(response_parts, "Exit code: $exit_code")
        end

        # If no output at all and success, use special format
        if isempty(response_parts) && exit_code == 0
            push!(response_parts, "<system>Tool ran without output or errors</system>")
        elseif isempty(response_parts)
            # Had an error but no output
            push!(response_parts, "Command failed with exit code: $exit_code (no output)")
        end

        result_text = join(response_parts)
        
        # Return success - non-zero exit codes are part of normal command output, not MCP errors
        # Only actual tool failures (exceptions) should set isError=true
        return create_content_response(result_text, is_error=false)
        
    catch e
        error_msg = "Failed to execute command: " * string(e)
        return create_content_response(error_msg, is_error=true)
    end
end