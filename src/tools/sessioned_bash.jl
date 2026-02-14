"""
Sessioned bash tool for MCP — persistent interactive shell sessions.

Provides a `SessionManager` that manages multiple concurrent shell sessions,
and four `MCPTool` subtypes (start, exec, stop, list) that can be registered
with an `MCPServer`.

The `start_cmd` factory function passed to `SessionManager` makes this generic:
callers provide a function `(params::Dict) -> (Cmd, Dict{String,Any} metadata)`
that turns tool-call arguments into the command to launch.
"""

using Random: randstring
using UUIDs: uuid4

# ═══════════════════════════════════════════════════════════════
# Types
# ═══════════════════════════════════════════════════════════════

"""
    BashSession

A persistent interactive bash session with piped I/O.
"""
mutable struct BashSession
    id::String
    process::Base.Process
    stdin_pipe::IO
    output_channel::Channel{String}
    reader_task::Task
    metadata::Dict{String,Any}
    created_at::Float64
    stderr_lines::Vector{String}   # accumulated during startup for error reporting
end

"""
    SessionManager(start_cmd; kwargs...)

Manages multiple persistent bash sessions.

`start_cmd` is called with the tool-call parameters dict and must return
`(cmd::Cmd, metadata::Dict{String,Any})`.  The `Cmd` is launched with piped
stdin/stdout; `metadata` is stored on the session for later display.
"""
mutable struct SessionManager
    sessions::Dict{String,BashSession}
    locks::Dict{String,ReentrantLock}
    start_cmd::Function
    max_output_chars::Int
    max_timeout_ms::Int
    default_timeout_ms::Int
    ready_timeout_s::Float64
    log::Function
    format_session::Function

    function SessionManager(start_cmd::Function;
            max_output_chars::Int=30000,
            max_timeout_ms::Int=600000,
            default_timeout_ms::Int=120000,
            ready_timeout_s::Float64=300.0,
            log::Function=msg -> (println(stderr, "[session] ", msg); flush(stderr)),
            format_session::Function=default_format_session)
        new(
            Dict{String,BashSession}(),
            Dict{String,ReentrantLock}(),
            start_cmd,
            max_output_chars,
            max_timeout_ms,
            default_timeout_ms,
            ready_timeout_s,
            log,
            format_session,
        )
    end
end

function default_format_session(session::BashSession)
    uptime = round(Int, time() - session.created_at)
    running = process_running(session.process)
    parts = ["ID: $(session.id)",
             "Status: $(running ? "running" : "exited")",
             "Uptime: $(uptime)s"]
    for (k, v) in session.metadata
        push!(parts, "$k: $v")
    end
    return "- " * join(parts, " | ")
end

# ═══════════════════════════════════════════════════════════════
# Utilities
# ═══════════════════════════════════════════════════════════════

function generate_marker()
    return "MCPSENTINEL" * randstring(['a':'z'; '0':'9'], 20)
end

"""
    timedtake!(ch, timeout_s)

Take from a channel with a timeout.  Checks `isready` before `isopen` so that
buffered items on a closed channel are still drained.
"""
function timedtake!(ch::Channel, timeout_s::Real)
    deadline = time() + timeout_s
    while time() < deadline
        isready(ch) && return take!(ch)
        isopen(ch) || error("Channel closed")
        sleep(0.02)
    end
    error("Timeout")
end

# ═══════════════════════════════════════════════════════════════
# Session lifecycle
# ═══════════════════════════════════════════════════════════════

"""
    start_session(manager, params) -> BashSession

Launch a new session using the manager's `start_cmd` factory.
"""
function start_session(manager::SessionManager, params::AbstractDict)
    cmd, metadata = manager.start_cmd(params)
    id = string(uuid4())
    manager.log("Starting session $id")

    # Launch with piped IO — stderr is captured separately so we can
    # report errors if the process fails during startup.
    inp = Pipe()
    out = Pipe()
    err = Pipe()
    proc = run(pipeline(cmd, stdin=inp, stdout=out, stderr=err), wait=false)
    close(inp.out)   # close read end in parent
    close(out.in)    # close write end in parent
    close(err.in)    # close write end in parent

    # Background reader for stdout: pushes lines into a channel
    ch = Channel{String}(10000)
    reader = @async begin
        try
            while !eof(out.out)
                line = readline(out.out)
                try put!(ch, line) catch; break end
            end
        catch e
            e isa EOFError || manager.log("Reader error for session $id: $e")
        finally
            try close(ch) catch end
        end
    end

    # Background reader for stderr: logs in real-time and accumulates
    # for error reporting.  After startup succeeds, stderr is merged
    # into stdout via `exec 2>&1` so this reader goes idle.
    stderr_lines = String[]
    @async begin
        try
            while !eof(err.out)
                line = readline(err.out)
                manager.log("stderr[$id]: $line")
                push!(stderr_lines, line)
            end
        catch e
            e isa EOFError || nothing
        end
    end

    session = BashSession(id, proc, inp.in, ch, reader, metadata, time(), stderr_lines)
    manager.sessions[id] = session
    manager.locks[id] = ReentrantLock()

    # Wait for the shell to become ready
    manager.log("Waiting for shell to become ready...")
    wait_for_ready(manager, session)
    manager.log("Session $id is ready")

    return session
end

"""
Wait until the shell is responsive by polling with sentinel commands.
"""
function wait_for_ready(manager::SessionManager, session::BashSession)
    marker = generate_marker()
    deadline = time() + manager.ready_timeout_s

    sleep(0.5)

    while time() < deadline
        if !process_running(session.process)
            # Process died — collect all available output for the error message
            sleep(0.5)  # give stderr reader time to drain
            stdout_lines = String[]
            while isready(session.output_channel)
                push!(stdout_lines, take!(session.output_channel))
            end
            parts = String[]
            if !isempty(session.stderr_lines)
                push!(parts, join(session.stderr_lines, "\n"))
            end
            if !isempty(stdout_lines)
                push!(parts, join(stdout_lines, "\n"))
            end
            output_msg = isempty(parts) ? "" : "\n\nProcess output:\n" * join(parts, "\n")
            error("Process exited during startup (exit code: $(session.process.exitcode))$output_msg")
        end

        try
            write(session.stdin_pipe, "echo $(marker)\n")
            flush(session.stdin_pipe)
        catch
            sleep(1); continue
        end

        inner_deadline = time() + 10.0
        while time() < inner_deadline
            try
                line = timedtake!(session.output_channel,
                                  min(2.0, inner_deadline - time()))
                if contains(line, marker)
                    # Drain stale marker echoes from previous polling iterations
                    sleep(0.3)
                    while isready(session.output_channel)
                        take!(session.output_channel)
                    end

                    # Permanently redirect stderr→stdout so all command output
                    # is captured through the single pipe, and commands like
                    # `cd` run in the main shell (no subshell wrapping).
                    write(session.stdin_pipe, "exec 2>&1\n")
                    flush(session.stdin_pipe)
                    sleep(0.1)
                    while isready(session.output_channel)
                        take!(session.output_channel)
                    end

                    return true
                end
            catch
                break
            end
        end

        sleep(1)
    end

    # Timed out — collect what we have for diagnostics
    parts = String[]
    if !isempty(session.stderr_lines)
        push!(parts, join(session.stderr_lines, "\n"))
    end
    stdout_lines = String[]
    while isready(session.output_channel)
        push!(stdout_lines, take!(session.output_channel))
    end
    if !isempty(stdout_lines)
        push!(parts, join(stdout_lines, "\n"))
    end
    output_msg = isempty(parts) ? "" : "\n\nProcess output:\n" * join(parts, "\n")
    error("Timeout waiting for shell ($(manager.ready_timeout_s)s)$output_msg")
end

"""
    exec_command(manager, session, command; timeout_ms)

Execute a bash command and return `(output, exit_code, process_died, timed_out)`.
"""
function exec_command(manager::SessionManager, session::BashSession,
                      command::String;
                      timeout_ms::Int=manager.default_timeout_ms)
    session_lock = get(manager.locks, session.id, nothing)
    if session_lock === nothing
        return ("Error: session has been stopped", 1, false, false)
    end

    lock(session_lock) do
        if !process_running(session.process) && !isopen(session.output_channel)
            return ("Error: process has exited", 1, true, false)
        end

        marker = generate_marker()

        # Run command directly in the main shell (no subshell) so state like
        # `cd` persists.  stderr already redirected via `exec 2>&1`.
        wrapped = "$(command)\n__MCP_EC__=\$?; printf '\\n$(marker)%d\\n' \"\$__MCP_EC__\"\n"

        try
            write(session.stdin_pipe, wrapped)
            flush(session.stdin_pipe)
        catch e
            return ("Error writing to stdin: $e", 1, false, false)
        end

        output = IOBuffer()
        exit_code = -1
        process_died = false
        timed_out = false
        timeout_s = timeout_ms / 1000
        deadline = time() + timeout_s

        while time() < deadline
            remaining = deadline - time()
            remaining <= 0 && break

            local line
            try
                line = timedtake!(session.output_channel, min(1.0, remaining))
            catch
                # Channel closed or timed-out on this take.
                # If the process died, drain remaining buffered items.
                if !process_running(session.process)
                    while isready(session.output_channel)
                        line = take!(session.output_channel)
                        idx = findfirst(marker, line)
                        if idx !== nothing
                            code_str = SubString(line, last(idx) + 1)
                            exit_code = tryparse(Int, code_str)
                            exit_code === nothing && (exit_code = -1)
                            @goto done
                        end
                        print(output, line, "\n")
                    end
                    process_died = true
                    break
                end
                continue
            end

            idx = findfirst(marker, line)
            if idx !== nothing
                code_str = SubString(line, last(idx) + 1)
                exit_code = tryparse(Int, code_str)
                exit_code === nothing && (exit_code = -1)
                break
            end

            print(output, line, "\n")
        end
        @label done

        if exit_code == -1 && !process_died
            timed_out = true
        end

        result = rstrip(String(take!(output)), '\n')

        if length(result) > manager.max_output_chars
            result = result[1:manager.max_output_chars] *
                     "\n... (output truncated at $(manager.max_output_chars) characters)"
        end

        return (result, exit_code, process_died, timed_out)
    end
end

"""
Stop a session and clean up resources.
"""
function stop_session(manager::SessionManager, session_id::String)
    session = get(manager.sessions, session_id, nothing)
    session === nothing && return false

    manager.log("Stopping session $session_id")

    try
        if process_running(session.process)
            try
                write(session.stdin_pipe, "exit\n")
                flush(session.stdin_pipe)
            catch end
            sleep(0.3)
            if process_running(session.process)
                kill(session.process)
            end
        end
    catch end

    try close(session.stdin_pipe) catch end
    try close(session.output_channel) catch end

    delete!(manager.sessions, session_id)
    delete!(manager.locks, session_id)
    return true
end

"""
Stop all sessions managed by this manager.
"""
function stop_all_sessions(manager::SessionManager)
    for id in collect(keys(manager.sessions))
        stop_session(manager, id)
    end
end

# ═══════════════════════════════════════════════════════════════
# MCP Tool Types
# ═══════════════════════════════════════════════════════════════

struct SessionStartTool <: MCPTool
    manager::SessionManager
    name::String
    description::String
    extra_properties::Dict{String,Any}
    required::Vector{String}
end

struct SessionExecTool <: MCPTool
    manager::SessionManager
    name::String
    description::String
end

struct SessionStopTool <: MCPTool
    manager::SessionManager
    name::String
    description::String
end

struct SessionListTool <: MCPTool
    manager::SessionManager
    name::String
    description::String
end

# ── Tool schemas ──────────────────────────────────────────────

function tool_schema(tool::SessionStartTool)
    Dict(
        "name" => tool.name,
        "description" => tool.description,
        "inputSchema" => Dict{String,Any}(
            "type" => "object",
            "properties" => tool.extra_properties,
            "required" => tool.required,
        ),
    )
end

function tool_schema(tool::SessionExecTool)
    Dict(
        "name" => tool.name,
        "description" => tool.description,
        "inputSchema" => Dict{String,Any}(
            "type" => "object",
            "properties" => Dict{String,Any}(
                "session_id" => Dict{String,Any}(
                    "type" => "string",
                    "description" => "The session ID returned by the start tool",
                ),
                "command" => Dict{String,Any}(
                    "type" => "string",
                    "description" => "The bash command to execute",
                ),
                "timeout" => Dict{String,Any}(
                    "type" => "number",
                    "description" => "Optional timeout in milliseconds (default $(tool.manager.default_timeout_ms), max $(tool.manager.max_timeout_ms))",
                ),
                "description" => Dict{String,Any}(
                    "type" => "string",
                    "description" => "Clear, concise description of what this command does",
                ),
            ),
            "required" => Any["session_id", "command"],
        ),
    )
end

function tool_schema(tool::SessionStopTool)
    Dict(
        "name" => tool.name,
        "description" => tool.description,
        "inputSchema" => Dict{String,Any}(
            "type" => "object",
            "properties" => Dict{String,Any}(
                "session_id" => Dict{String,Any}(
                    "type" => "string",
                    "description" => "The session ID to stop",
                ),
            ),
            "required" => Any["session_id"],
        ),
    )
end

function tool_schema(tool::SessionListTool)
    Dict(
        "name" => tool.name,
        "description" => tool.description,
        "inputSchema" => Dict{String,Any}(
            "type" => "object",
            "properties" => Dict{String,Any}(),
            "additionalProperties" => false,
        ),
    )
end

# ── Execute methods ───────────────────────────────────────────

function execute(tool::SessionStartTool, params::AbstractDict)
    try
        session = start_session(tool.manager, params)
        text = "Session started successfully.\n\nSession ID: $(session.id)"
        for (k, v) in session.metadata
            text *= "\n$(k): $(v)"
        end
        text *= "\n\nUse the exec tool with this session_id to run commands."
        return create_content_response(text)
    catch e
        return create_content_response(
            "Failed to start session: $(sprint(showerror, e))",
            is_error=true,
        )
    end
end

function execute(tool::SessionExecTool, params::AbstractDict)
    session_id = get(params, "session_id", "")
    command = get(params, "command", "")
    timeout_ms = Int(min(
        get(params, "timeout", tool.manager.default_timeout_ms),
        tool.manager.max_timeout_ms,
    ))

    session = get(tool.manager.sessions, session_id, nothing)
    if session === nothing
        return create_content_response(
            "Error: no session with ID '$(session_id)'. Use the list tool to see active sessions.",
            is_error=true,
        )
    end

    output, exit_code, process_died, timed_out =
        exec_command(tool.manager, session, command; timeout_ms)

    text = output
    if exit_code >= 0
        text *= "\n[Exit code: $exit_code]"
    elseif process_died
        text *= "\n[Process exited]"
    elseif timed_out
        text *= "\n[Command timed out after $(timeout_ms)ms]"
    end

    return create_content_response(text, is_error=exit_code != 0)
end

function execute(tool::SessionStopTool, params::AbstractDict)
    session_id = get(params, "session_id", "")
    if stop_session(tool.manager, session_id)
        return create_content_response("Session '$(session_id)' stopped.")
    else
        return create_content_response(
            "Error: no session with ID '$(session_id)'.",
            is_error=true,
        )
    end
end

function execute(tool::SessionListTool, params::AbstractDict)
    if isempty(tool.manager.sessions)
        return create_content_response("No active sessions.")
    end

    lines = [tool.manager.format_session(s)
             for (_, s) in tool.manager.sessions]
    return create_content_response("Active sessions:\n" * join(lines, "\n"))
end

# ═══════════════════════════════════════════════════════════════
# Convenience registration
# ═══════════════════════════════════════════════════════════════

"""
    register_sessioned_bash!(server, manager; prefix, descriptions..., start_extra_properties, start_required)

Register the four session management tools (start, exec, stop, list) with an
`MCPServer`.  Tool names are `\$(prefix)_start`, etc.
"""
function register_sessioned_bash!(server::MCPServer, manager::SessionManager;
        prefix::String="session",
        start_description::String="Start a new interactive bash session",
        exec_description::String="Execute a command in a running bash session",
        stop_description::String="Stop a running bash session",
        list_description::String="List active bash sessions",
        start_extra_properties::Dict{String,Any}=Dict{String,Any}(),
        start_required::Vector{String}=String[])

    register_tool!(server, "$(prefix)_start",
        SessionStartTool(manager, "$(prefix)_start", start_description,
                         start_extra_properties, start_required))
    register_tool!(server, "$(prefix)_exec",
        SessionExecTool(manager, "$(prefix)_exec", exec_description))
    register_tool!(server, "$(prefix)_stop",
        SessionStopTool(manager, "$(prefix)_stop", stop_description))
    register_tool!(server, "$(prefix)_list",
        SessionListTool(manager, "$(prefix)_list", list_description))

    return server
end
