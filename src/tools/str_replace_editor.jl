"""
String replacement editor tool for MCP
"""

mutable struct StrReplaceEditorTool <: MCPTool
    base_path::String
    
    function StrReplaceEditorTool(; base_path::String=pwd())
        new(base_path)
    end
end

function tool_schema(::StrReplaceEditorTool)
    return Dict(
        "name" => "str_replace_editor",
        "description" => "Edit files using string replacement",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "command" => Dict(
                    "type" => "string",
                    "enum" => ["view", "str_replace", "create"],
                    "description" => "The command to execute: view, str_replace, or create"
                ),
                "path" => Dict(
                    "type" => "string",
                    "description" => "Path to the file to edit (relative to base path)"
                ),
                "old_str" => Dict(
                    "type" => "string",
                    "description" => "String to replace (for str_replace command)"
                ),
                "new_str" => Dict(
                    "type" => "string",
                    "description" => "Replacement string (for str_replace command)"
                ),
                "file_text" => Dict(
                    "type" => "string",
                    "description" => "Content for new file (for create command)"
                )
            ),
            "required" => ["command", "path"]
        )
    )
end

function execute(tool::StrReplaceEditorTool, params::Dict)
    command = get(params, "command", "view")
    path = get(params, "path", nothing)
    
    if path === nothing
        return Dict("content" => [Dict(
            "type" => "text",
            "text" => "Error: No path provided"
        )])
    end
    
    # Resolve path relative to base path
    full_path = isabspath(path) ? path : joinpath(tool.base_path, path)
    
    try
        if command == "view"
            # View file with line numbers
            if !isfile(full_path)
                return Dict("content" => [Dict(
                    "type" => "text",
                    "text" => "Error: File not found: $path"
                )])
            end
            
            lines = readlines(full_path)
            numbered_lines = [string(i, "\t", line) for (i, line) in enumerate(lines)]
            content = join(numbered_lines, "\n")
            
            return Dict("content" => [Dict(
                "type" => "text",
                "text" => content
            )])
            
        elseif command == "str_replace"
            # Replace string in file
            old_str = get(params, "old_str", nothing)
            new_str = get(params, "new_str", nothing)
            
            if old_str === nothing || new_str === nothing
                return Dict("content" => [Dict(
                    "type" => "text",
                    "text" => "Error: Both old_str and new_str are required for str_replace"
                )])
            end
            
            if !isfile(full_path)
                return Dict("content" => [Dict(
                    "type" => "text",
                    "text" => "Error: File not found: $path"
                )])
            end
            
            content = read(full_path, String)
            
            if !occursin(old_str, content)
                return Dict("content" => [Dict(
                    "type" => "text",
                    "text" => "Error: String not found in file"
                )])
            end
            
            # Count occurrences
            occurrences = length(collect(eachmatch(Regex(escape_string(old_str)), content)))
            
            # Replace the string
            new_content = replace(content, old_str => new_str)
            write(full_path, new_content)
            
            # Show the result with line numbers
            lines = split(new_content, '\n')
            
            # Find lines that were changed
            changed_lines = Int[]
            for (i, line) in enumerate(lines)
                if occursin(new_str, line)
                    push!(changed_lines, i)
                end
            end
            
            # Show context around changed lines
            result_lines = String[]
            for line_num in changed_lines
                start_line = max(1, line_num - 2)
                end_line = min(length(lines), line_num + 2)
                
                for i in start_line:end_line
                    prefix = i == line_num ? ">>> " : "    "
                    push!(result_lines, "$prefix$i\t$(lines[i])")
                end
                push!(result_lines, "")
            end
            
            result = join(result_lines, "\n")
            message = "Replaced $occurrences occurrence(s) in $path\n\n$result"
            
            return Dict("content" => [Dict(
                "type" => "text",
                "text" => message
            )])
            
        elseif command == "create"
            # Create new file
            file_text = get(params, "file_text", "")
            
            # Ensure parent directory exists
            parent_dir = dirname(full_path)
            if !isdir(parent_dir)
                mkpath(parent_dir)
            end
            
            write(full_path, file_text)
            
            # Show created file with line numbers
            lines = split(file_text, '\n')
            numbered_lines = [string(i, "\t", line) for (i, line) in enumerate(lines)]
            content = join(numbered_lines, "\n")
            
            message = "Created file: $path\n\n$content"
            
            return Dict("content" => [Dict(
                "type" => "text",
                "text" => message
            )])
            
        else
            return Dict("content" => [Dict(
                "type" => "text",
                "text" => "Error: Unknown command: $command"
            )])
        end
        
    catch e
        error_msg = "Error executing command: " * string(e)
        return Dict("content" => [Dict(
            "type" => "text",
            "text" => error_msg
        )])
    end
end