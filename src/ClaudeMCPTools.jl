module ClaudeMCPTools

using JSON

export MCPServer, MCPTool, register_tool!, handle_request
export BashTool, StrReplaceEditorTool
export run_stdio_server, run_http_server

# Include components
include("types.jl")
include("tools/bash.jl")
include("tools/str_replace_editor.jl")
include("server.jl")
include("protocol.jl")

end # module ClaudeMCPTools
