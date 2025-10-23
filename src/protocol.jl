"""
MCP Protocol utilities and helpers
"""

"""
    create_content_response(text::String; is_error::Bool=false)

Create a properly formatted MCP content response with isError field.
"""
function create_content_response(text::String; is_error::Bool=false)
    return Dict(
        "content" => [Dict(
            "type" => "text",
            "text" => text
        )],
        "isError" => is_error
    )
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