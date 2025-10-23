# ClaudeMCPTools.jl

A Julia implementation of basic Model Context Protocol (MCP) tools for Claude and other AI assistants.

## Features

- **MCP Server**: Full implementation of the Model Context Protocol server
- **Bash Tool**: Execute shell commands with proper stdout/stderr/exit code handling
- **String Replace Editor Tool**: Edit files using string replacement operations
- **Extensible Architecture**: Easy to add new tools by implementing the `MCPTool` interface

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/JuliaComputing/ClaudeMCPTools.jl")
```

## Quick Start

```julia
using ClaudeMCPTools

# Create an MCP server
server = MCPServer(name="MyServer", version="1.0.0")

# Register tools
register_tool!(server, "bash", BashTool())
register_tool!(server, "editor", StrReplaceEditorTool())

# Run the server in stdio mode (for MCP communication)
run_stdio_server(server)
```

## Creating Custom Tools

To create a custom tool, implement the `MCPTool` interface:

```julia
struct MyTool <: MCPTool
    # tool fields
end

function tool_schema(tool::MyTool)
    return Dict(
        "name" => "my_tool",
        "description" => "Description of my tool",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                # Define parameters
            ),
            "required" => [
                # List required parameters
            ]
        )
    )
end

function execute(tool::MyTool, params::Dict)
    # Implement tool logic
    # Return Dict("content" => [Dict("type" => "text", "text" => result)])
end
```

## Tools

### BashTool

Execute shell commands with full output capture:

```julia
bash = BashTool(working_dir="/path/to/dir", env=Dict("VAR" => "value"))
result = execute(bash, Dict("command" => "echo 'Hello World'"))
```

### StrReplaceEditorTool

Edit files using string replacement:

```julia
editor = StrReplaceEditorTool(base_path="/path/to/project")

# View a file
execute(editor, Dict("command" => "view", "path" => "file.txt"))

# Replace text
execute(editor, Dict(
    "command" => "str_replace",
    "path" => "file.txt",
    "old_str" => "old text",
    "new_str" => "new text"
))

# Create a new file
execute(editor, Dict(
    "command" => "create",
    "path" => "new_file.txt",
    "file_text" => "content"
))
```

## Protocol

ClaudeMCPTools.jl implements the Model Context Protocol version 2024-11-05, supporting:

- `initialize`: Initialize the server connection
- `tools/list`: List available tools
- `tools/call`: Execute a tool with parameters

## Testing

```julia
using Pkg
Pkg.test("ClaudeMCPTools")
```

## License

MIT License