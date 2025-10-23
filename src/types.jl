"""
Types and abstractions for MCP tools
"""

# Abstract type for all MCP tools
abstract type MCPTool end

"""
    MCPServer

A Model Context Protocol server that manages tools and handles requests.
"""
mutable struct MCPServer
    tools::Dict{String, MCPTool}
    metadata::Dict{String, Any}
    
    function MCPServer(; name::String="ClaudeMCPTools", version::String="0.1.0")
        new(
            Dict{String, MCPTool}(),
            Dict(
                "name" => name,
                "version" => version
            )
        )
    end
end

"""
    tool_schema(tool::MCPTool)

Return the JSON schema for a tool.
"""
function tool_schema(tool::MCPTool)
    error("tool_schema not implemented for $(typeof(tool))")
end

"""
    execute(tool::MCPTool, params::Dict)

Execute a tool with the given parameters.
Returns a Dict with a "content" field containing an array of content items.
"""
function execute(tool::MCPTool, params::Dict)
    error("execute not implemented for $(typeof(tool))")
end

"""
    register_tool!(server::MCPServer, name::String, tool::MCPTool)

Register a tool with the server.
"""
function register_tool!(server::MCPServer, name::String, tool::MCPTool)
    server.tools[name] = tool
    return server
end