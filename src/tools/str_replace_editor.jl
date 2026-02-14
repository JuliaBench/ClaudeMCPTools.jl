"""
String replacement editor tool for MCP
"""

mutable struct StrReplaceEditorTool <: MCPTool
    base_path::String
    uid::Union{Int, Nothing}
    
    function StrReplaceEditorTool(; base_path::String=pwd(), uid::Union{Int, Nothing}=nothing)
        new(base_path, uid)
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
                "view_range" => Dict(
                    "type" => "array",
                    "items" => Dict("type" => "integer"),
                    "minItems" => 2,
                    "maxItems" => 2,
                    "description" => "Line range to view [start_line, end_line] (for view command). Use -1 for end_line to view to end of file"
                ),
                "old_str" => Dict(
                    "type" => "string",
                    "description" => "String to replace (for str_replace command). Must be unique in the file unless replace_all is true."
                ),
                "new_str" => Dict(
                    "type" => "string",
                    "description" => "Replacement string (for str_replace command)"
                ),
                "replace_all" => Dict(
                    "type" => "boolean",
                    "description" => "Replace all occurrences of old_str (default: false). When false, old_str must match exactly once."
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

function execute(tool::StrReplaceEditorTool, params::AbstractDict)
    command = get(params, "command", "view")
    path = get(params, "path", nothing)
    
    if path === nothing
        return create_content_response("Error: No path provided", is_error=true)
    end
    
    # Resolve path relative to base path
    full_path = isabspath(path) ? path : joinpath(tool.base_path, path)
    
    try
        if command == "view"
            # Get view_range parameter if provided
            view_range = get(params, "view_range", nothing)
            
            # Check if path is a directory
            if isdir(full_path)
                # view_range is not allowed for directories
                if view_range !== nothing
                    return create_content_response("Error: The view_range parameter is not allowed when path points to a directory", is_error=true)
                end
                
                # List directory contents manually, walking up to 2 levels deep
                # and excluding hidden items (starting with .) at all levels
                paths = String[]
                
                # Add the root directory itself
                push!(paths, full_path)
                
                # Level 1: immediate children
                try
                    for item in readdir(full_path)
                        # Skip hidden files/directories
                        if startswith(item, ".")
                            continue
                        end
                        
                        item_path = joinpath(full_path, item)
                        push!(paths, item_path)
                        
                        # Level 2: children of directories at level 1
                        if isdir(item_path)
                            try
                                for subitem in readdir(item_path)
                                    # Skip hidden files/directories at level 2
                                    if startswith(subitem, ".")
                                        continue
                                    end
                                    
                                    subitem_path = joinpath(item_path, subitem)
                                    push!(paths, subitem_path)
                                end
                            catch e
                                # Ignore errors reading subdirectories (permissions, etc.)
                            end
                        end
                    end
                catch e
                    # If we can't read the directory, return an error
                    return create_content_response("Error reading directory: $e", is_error=true)
                end
                
                # Join all paths with newlines, similar to find output
                result = join(paths, "\n")
                content = "Here's the files and directories up to 2 levels deep in $path, excluding hidden items:\n$result"
                
                return create_content_response(content, is_error=false)
            end
            
            # View file with line numbers
            if !isfile(full_path)
                return create_content_response("Error: Path not found: $path", is_error=true)
            end
            
            lines = readlines(full_path)
            n_lines = length(lines)
            
            # Handle view_range if provided
            if view_range !== nothing
                # Validate view_range
                if !isa(view_range, Array) || length(view_range) != 2 || !all(isa(x, Integer) for x in view_range)
                    return create_content_response("Error: Invalid view_range. It should be a list of two integers.", is_error=true)
                end
                
                start_line, end_line = view_range
                
                # Validate start_line
                if start_line < 1 || start_line > n_lines
                    return create_content_response("Error: Invalid view_range: $view_range. Its first element $start_line should be within the range of lines of the file: [1, $n_lines]", is_error=true)
                end
                
                # Validate end_line
                if end_line != -1 && end_line > n_lines
                    return create_content_response("Error: Invalid view_range: $view_range. Its second element $end_line should be smaller than the number of lines in the file: $n_lines", is_error=true)
                end
                
                if end_line != -1 && end_line < start_line
                    return create_content_response("Error: Invalid view_range: $view_range. Its second element $end_line should be larger or equal than its first $start_line", is_error=true)
                end
                
                # Extract the requested range
                if end_line == -1
                    selected_lines = lines[start_line:end]
                    actual_end = n_lines
                else
                    selected_lines = lines[start_line:end_line]
                    actual_end = end_line
                end
                
                # Create numbered output with actual line numbers
                numbered_lines = [string(start_line + i - 1, "\t", line) for (i, line) in enumerate(selected_lines)]
                content = "Here's the content of $path with line numbers (which has a total of $n_lines lines) with view_range=[$start_line, $end_line]:\n"
                content *= join(numbered_lines, "\n")
            else
                # Show all lines with numbers
                numbered_lines = [string(i, "\t", line) for (i, line) in enumerate(lines)]
                content = "Here's the content of $path with line numbers:\n"
                content *= join(numbered_lines, "\n")
            end
            
            return create_content_response(content, is_error=false)
            
        elseif command == "str_replace"
            # Check if path is a directory
            if isdir(full_path)
                return create_content_response("Error: Cannot use str_replace on a directory: $path", is_error=true)
            end
            
            # Replace string in file
            old_str = get(params, "old_str", nothing)
            new_str = get(params, "new_str", nothing)
            replace_all = get(params, "replace_all", false)

            if old_str === nothing || new_str === nothing
                return create_content_response("Error: Both old_str and new_str are required for str_replace", is_error=true)
            end

            if !isfile(full_path)
                return create_content_response("Error: File not found: $path", is_error=true)
            end

            content = read(full_path, String)

            if !occursin(old_str, content)
                return create_content_response("Error: String not found in file", is_error=true)
            end

            # Count occurrences using findnext
            occurrences = 0
            occurrence_lines = Int[]
            pos = 1
            while true
                range = findnext(old_str, content, pos)
                if isnothing(range)
                    break
                end
                occurrences += 1
                # Find line number of this occurrence
                line_num = count(==('\n'), SubString(content, 1, first(range))) + 1
                push!(occurrence_lines, line_num)
                pos = last(range) + 1
            end

            # Enforce uniqueness unless replace_all is true
            if !replace_all && occurrences > 1
                lines_str = join(occurrence_lines, ", ")
                return create_content_response(
                    "Error: old_str matches $occurrences times (at lines $lines_str). " *
                    "Provide a larger, unique string for old_str, or set replace_all=true.",
                    is_error=true)
            end

            # Replace the string
            new_content = replace(content, old_str => new_str; count=replace_all ? typemax(Int) : 1)
            write(full_path, new_content)
            
            # Preserve ownership if UID is specified (in case file permissions changed)
            if tool.uid !== nothing
                try
                    # Use chown to ensure the file keeps the correct ownership
                    run(`chown $(tool.uid) $full_path`)
                catch e
                    # Log warning but don't fail the operation
                    @warn "Could not set file ownership" uid=tool.uid path=full_path error=e
                end
            end
            
            # Return concise message
            if occurrences == 1
                message = "The file $path has been edited successfully."
            else
                message = "The file $path has been edited successfully. Made $occurrences replacements."
            end

            return create_content_response(message, is_error=false)
            
        elseif command == "create"
            # Check if path already exists as a directory
            if isdir(full_path)
                return create_content_response("Error: Cannot create file at $path - a directory already exists there", is_error=true)
            end
            
            # Check if file already exists
            if isfile(full_path)
                return create_content_response("Error: File already exists at $path. Cannot overwrite with create command", is_error=true)
            end
            
            # Create new file
            file_text = get(params, "file_text", "")
            
            # Ensure parent directory exists
            parent_dir = dirname(full_path)
            if !isdir(parent_dir)
                mkpath(parent_dir)
            end
            
            write(full_path, file_text)
            
            # Set ownership if UID is specified
            if tool.uid !== nothing
                try
                    # Use chown to set the file ownership
                    run(`chown $(tool.uid) $full_path`)
                catch e
                    # Log warning but don't fail the operation
                    @warn "Could not set file ownership" uid=tool.uid path=full_path error=e
                end
            end
            
            # Return concise message
            num_lines = count(c -> c == '\n', file_text) + 1
            message = "File created successfully at $path"

            return create_content_response(message, is_error=false)
            
        else
            return create_content_response("Error: Unknown command: $command", is_error=true)
        end
        
    catch e
        error_msg = "Error executing command: " * string(e)
        return create_content_response(error_msg, is_error=true)
    end
end