#!/usr/bin/env julia

using ClaudeMCPTools

# Create a temporary directory for testing
test_dir = mktempdir()
println("Testing in directory: $test_dir")

# Create a tool instance
tool = ClaudeMCPTools.StrReplaceEditorTool(base_path=test_dir)

# Test 1: Create a file
println("\nTest 1: Creating a file")
params = Dict(
    "command" => "create",
    "path" => "test.txt",
    "file_text" => "Hello World\nThis is a test\nAnother line"
)
result = ClaudeMCPTools.execute(tool, params)
println("Response: ", result["content"][1]["text"])

# Test 2: View the file (should still show full content)
println("\nTest 2: Viewing the file")
params = Dict(
    "command" => "view",
    "path" => "test.txt"
)
result = ClaudeMCPTools.execute(tool, params)
response_preview = split(result["content"][1]["text"], '\n')[1]
println("Response starts with: ", response_preview)

# Test 3: Replace single occurrence
println("\nTest 3: Replace single occurrence")
params = Dict(
    "command" => "str_replace",
    "path" => "test.txt",
    "old_str" => "Hello World",
    "new_str" => "Hello Julia"
)
result = ClaudeMCPTools.execute(tool, params)
println("Response: ", result["content"][1]["text"])

# Test 4: Replace multiple occurrences
println("\nTest 4: Replace multiple occurrences")
# First create a file with multiple occurrences
params = Dict(
    "command" => "create",
    "path" => "test2.txt",
    "file_text" => "foo bar\nfoo baz\nfoo qux"
)
result = ClaudeMCPTools.execute(tool, params)
println("Created test2.txt: ", result["content"][1]["text"])

# Now replace
params = Dict(
    "command" => "str_replace",
    "path" => "test2.txt",
    "old_str" => "foo",
    "new_str" => "bar"
)
result = ClaudeMCPTools.execute(tool, params)
println("Response: ", result["content"][1]["text"])

# Clean up
rm(test_dir, recursive=true)
println("\nTests completed!")