"""
MCP Protocol utilities and helpers
"""

"""
    create_content_response(text::String)

Create a properly formatted MCP content response.
"""
function create_content_response(text::String)
    return Dict("content" => [Dict(
        "type" => "text",
        "text" => text
    )])
end

"""
    create_error_response(code::Int, message::String)

Create a properly formatted MCP error response.
"""
function create_error_response(code::Int, message::String)
    return Dict("error" => Dict(
        "code" => code,
        "message" => message
    ))
end