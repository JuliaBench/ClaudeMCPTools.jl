module ClaudeMCPTools

using JSON
using Sockets

export MCPServer, MCPTool, register_tool!, handle_request
export BashTool, StrReplaceEditorTool
export BashSession, SessionManager
export SessionStartTool, SessionExecTool, SessionStopTool, SessionListTool
export register_sessioned_bash!, start_session, exec_command
export stop_session, stop_all_sessions
export run_stdio_server, run_unix_socket_server

# Include components
include("types.jl")
include("protocol.jl")
include("tools/bash.jl")
include("tools/str_replace_editor.jl")
include("tools/sessioned_bash.jl")
include("server.jl")

end # module ClaudeMCPTools
