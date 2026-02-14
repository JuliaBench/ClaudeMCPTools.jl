"""
Sessioned string replacement editor tool for MCP.

Provides file viewing and editing inside a running session by proxying
operations through `exec_command`.  File content is transferred via base64
to avoid shell-escaping issues and preserve exact content (including trailing
newlines and special characters).
"""

using Base64: base64encode, base64decode

# ── Helpers ───────────────────────────────────────────────────

"""Shell-escape a string using single quotes."""
function _shell_escape(s::AbstractString)
    return "'" * replace(s, "'" => "'\\''") * "'"
end

"""Run a command in the session, returning (output, exit_code)."""
function _sexec(manager::SessionManager, session::BashSession, cmd::String;
                timeout_ms::Int=manager.default_timeout_ms)
    output, exit_code, process_died, timed_out =
        exec_command(manager, session, cmd; timeout_ms)
    if process_died
        return (output, -1)
    elseif timed_out
        return (output, -2)
    end
    return (output, exit_code)
end

# ── Tool type ─────────────────────────────────────────────────

struct SessionedStrReplaceEditorTool <: MCPTool
    manager::SessionManager
    name::String
    description::String
end

function tool_schema(tool::SessionedStrReplaceEditorTool)
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
                    "enum" => ["view", "str_replace", "create"],
                    "description" => "The command to execute: view, str_replace, or create",
                ),
                "path" => Dict{String,Any}(
                    "type" => "string",
                    "description" => "Absolute path to the file inside the session",
                ),
                "view_range" => Dict{String,Any}(
                    "type" => "array",
                    "items" => Dict("type" => "integer"),
                    "minItems" => 2,
                    "maxItems" => 2,
                    "description" => "Line range to view [start_line, end_line] (for view command). Use -1 for end_line to view to end of file",
                ),
                "old_str" => Dict{String,Any}(
                    "type" => "string",
                    "description" => "String to replace (for str_replace command). Must be unique in the file unless replace_all is true.",
                ),
                "new_str" => Dict{String,Any}(
                    "type" => "string",
                    "description" => "Replacement string (for str_replace command)",
                ),
                "replace_all" => Dict{String,Any}(
                    "type" => "boolean",
                    "description" => "Replace all occurrences of old_str (default: false). When false, old_str must match exactly once.",
                ),
                "file_text" => Dict{String,Any}(
                    "type" => "string",
                    "description" => "Content for new file (for create command)",
                ),
            ),
            "required" => Any["session_id", "command", "path"],
        ),
    )
end

# ── Execute ───────────────────────────────────────────────────

function execute(tool::SessionedStrReplaceEditorTool, params::AbstractDict)
    session_id = get(params, "session_id", "")
    command = get(params, "command", "view")
    path = get(params, "path", nothing)

    if path === nothing
        return create_content_response("Error: No path provided", is_error=true)
    end

    session = get(tool.manager.sessions, session_id, nothing)
    if session === nothing
        return create_content_response(
            "Error: no session with ID '$(session_id)'. Use the list tool to see active sessions.",
            is_error=true)
    end

    try
        if command == "view"
            return _sessioned_view(tool.manager, session, path, params)
        elseif command == "str_replace"
            return _sessioned_str_replace(tool.manager, session, path, params)
        elseif command == "create"
            return _sessioned_create(tool.manager, session, path, params)
        else
            return create_content_response("Error: Unknown command: $command",
                                           is_error=true)
        end
    catch e
        return create_content_response(
            "Error executing command: $(sprint(showerror, e))",
            is_error=true)
    end
end

# ── View ──────────────────────────────────────────────────────

function _sessioned_view(manager, session, path, params)
    view_range = get(params, "view_range", nothing)
    epath = _shell_escape(path)

    # Determine path type
    output, ec = _sexec(manager, session,
        "test -d $epath && echo DIR || (test -f $epath && echo FILE || echo NOTFOUND)")
    type_str = strip(output)

    if type_str == "NOTFOUND"
        return create_content_response("Error: Path not found: $path",
                                       is_error=true)
    end

    if type_str == "DIR"
        if view_range !== nothing
            return create_content_response(
                "Error: The view_range parameter is not allowed when path points to a directory",
                is_error=true)
        end
        output, _ = _sexec(manager, session,
            "find $epath -maxdepth 2 -not -path '*/.*' 2>/dev/null")
        return create_content_response(
            "Here's the files and directories up to 2 levels deep in $path, excluding hidden items:\n$output")
    end

    # File view
    if view_range !== nothing
        if !isa(view_range, AbstractVector) || length(view_range) != 2
            return create_content_response(
                "Error: Invalid view_range. It should be a list of two integers.",
                is_error=true)
        end
        start_line = Int(view_range[1])
        end_line = Int(view_range[2])

        # Get total lines
        output, _ = _sexec(manager, session, "wc -l < $epath")
        n_lines = tryparse(Int, strip(output))
        if n_lines === nothing
            return create_content_response("Error: Could not read file: $path",
                                           is_error=true)
        end

        if start_line < 1 || start_line > n_lines
            return create_content_response(
                "Error: Invalid view_range: start_line $start_line out of range [1, $n_lines]",
                is_error=true)
        end
        if end_line != -1 && end_line > n_lines
            return create_content_response(
                "Error: Invalid view_range: end_line $end_line exceeds file length $n_lines",
                is_error=true)
        end
        if end_line != -1 && end_line < start_line
            return create_content_response(
                "Error: Invalid view_range: end_line $end_line < start_line $start_line",
                is_error=true)
        end

        if end_line == -1
            awk_cond = "NR>=$start_line"
        else
            awk_cond = "NR>=$start_line && NR<=$end_line"
        end
        output, _ = _sexec(manager, session,
            "awk '$awk_cond {printf \"%d\\t%s\\n\", NR, \$0}' $epath")
        return create_content_response(
            "Here's the content of $path with line numbers (which has a total of $n_lines lines) with view_range=[$start_line, $end_line]:\n$output")
    else
        output, _ = _sexec(manager, session,
            "awk '{printf \"%d\\t%s\\n\", NR, \$0}' $epath")
        return create_content_response(
            "Here's the content of $path with line numbers:\n$output")
    end
end

# ── String replace ────────────────────────────────────────────

function _sessioned_str_replace(manager, session, path, params)
    old_str = get(params, "old_str", nothing)
    new_str = get(params, "new_str", nothing)
    replace_all = get(params, "replace_all", false)
    epath = _shell_escape(path)

    if old_str === nothing || new_str === nothing
        return create_content_response(
            "Error: Both old_str and new_str are required for str_replace",
            is_error=true)
    end

    # Read file content via base64 for exact preservation
    raw_output, ec = _sexec(manager, session, "base64 $epath")
    if ec != 0
        return create_content_response("Error: File not found: $path",
                                       is_error=true)
    end

    content = String(base64decode(filter(!isspace, raw_output)))

    if !occursin(old_str, content)
        return create_content_response("Error: String not found in file",
                                       is_error=true)
    end

    # Count occurrences
    occurrences = 0
    occurrence_lines = Int[]
    pos = 1
    while true
        range = findnext(old_str, content, pos)
        isnothing(range) && break
        occurrences += 1
        line_num = count(==('\n'), SubString(content, 1, first(range))) + 1
        push!(occurrence_lines, line_num)
        pos = last(range) + 1
    end

    if !replace_all && occurrences > 1
        lines_str = join(occurrence_lines, ", ")
        return create_content_response(
            "Error: old_str matches $occurrences times (at lines $lines_str). " *
            "Provide a larger, unique string for old_str, or set replace_all=true.",
            is_error=true)
    end

    new_content = replace(content, old_str => new_str;
                          count=replace_all ? typemax(Int) : 1)

    # Write back via base64 heredoc
    _write_via_base64(manager, session, path, new_content) || return create_content_response(
        "Error: Failed to write file: $path", is_error=true)

    if occurrences == 1
        return create_content_response("The file $path has been edited successfully.")
    else
        return create_content_response(
            "The file $path has been edited successfully. Made $occurrences replacements.")
    end
end

# ── Create ────────────────────────────────────────────────────

function _sessioned_create(manager, session, path, params)
    file_text = get(params, "file_text", "")
    epath = _shell_escape(path)

    # Check if path already exists
    output, _ = _sexec(manager, session,
        "test -e $epath && echo EXISTS || echo NOTEXISTS")
    if strip(output) == "EXISTS"
        return create_content_response(
            "Error: File already exists at $path. Cannot overwrite with create command.",
            is_error=true)
    end

    # Create parent directory
    dir = dirname(path)  # works for Unix paths
    if !isempty(dir)
        _sexec(manager, session, "mkdir -p " * _shell_escape(dir))
    end

    _write_via_base64(manager, session, path, file_text) || return create_content_response(
        "Error: Failed to create file: $path", is_error=true)

    return create_content_response("File created successfully at $path")
end

# ── Write helper ──────────────────────────────────────────────

"""Write `content` to `path` in the session using base64 + heredoc."""
function _write_via_base64(manager::SessionManager, session::BashSession,
                           path::String, content::AbstractString)
    b64 = base64encode(content)
    marker = "MCPWRITEEOF" * randstring(['a':'z'; '0':'9'], 16)
    write_cmd = "base64 -d > " * _shell_escape(path) *
                " << '" * marker * "'\n" * b64 * "\n" * marker
    _, ec = _sexec(manager, session, write_cmd)
    return ec == 0
end
