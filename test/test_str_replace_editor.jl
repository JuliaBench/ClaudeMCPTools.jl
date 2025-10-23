@testset "StrReplaceEditorTool" begin
    # Import functions for testing
    using ClaudeMCPTools: tool_schema, execute
    
    mktempdir() do tmpdir
        editor = StrReplaceEditorTool(base_path=tmpdir)
        
        @testset "Schema" begin
            schema = tool_schema(editor)
            @test schema["name"] == "str_replace_editor"
            @test haskey(schema, "description")
            @test haskey(schema, "inputSchema")
            @test "command" in schema["inputSchema"]["required"]
            @test "path" in schema["inputSchema"]["required"]
        end
        
        @testset "Create file" begin
            # Create a new file
            result = execute(editor, Dict(
                "command" => "create",
                "path" => "test.txt",
                "file_text" => "Line 1\nLine 2\nLine 3"
            ))
            
            @test haskey(result, "content")
            text = result["content"][1]["text"]
            @test occursin("File created successfully", text)
            @test occursin("test.txt", text)
            
            # Verify file was actually created
            @test isfile(joinpath(tmpdir, "test.txt"))
            @test read(joinpath(tmpdir, "test.txt"), String) == "Line 1\nLine 2\nLine 3"
        end
        
        @testset "View file" begin
            # Create a test file
            test_file = joinpath(tmpdir, "view_test.txt")
            write(test_file, "First line\nSecond line\nThird line")
            
            # View the file
            result = execute(editor, Dict(
                "command" => "view",
                "path" => "view_test.txt"
            ))
            
            @test haskey(result, "content")
            text = result["content"][1]["text"]
            @test occursin("1\tFirst line", text)
            @test occursin("2\tSecond line", text)
            @test occursin("3\tThird line", text)
            
            # Test viewing non-existent file
            result = execute(editor, Dict(
                "command" => "view",
                "path" => "nonexistent.txt"
            ))
            @test occursin("Error", result["content"][1]["text"])
            @test occursin("not found", result["content"][1]["text"])
        end
        
        @testset "String replacement" begin
            # Create a test file
            test_file = joinpath(tmpdir, "replace_test.txt")
            write(test_file, "Hello World\nThis is a test\nHello again")
            
            # Replace string
            result = execute(editor, Dict(
                "command" => "str_replace",
                "path" => "replace_test.txt",
                "old_str" => "Hello",
                "new_str" => "Hi"
            ))
            
            @test haskey(result, "content")
            text = result["content"][1]["text"]
            @test occursin("edited successfully", text)
            @test occursin("2 replacements", text)
            
            # Verify file was modified
            content = read(test_file, String)
            @test occursin("Hi World", content)
            @test occursin("Hi again", content)
            @test !occursin("Hello", content)
            
            # Test replacing non-existent string
            result = execute(editor, Dict(
                "command" => "str_replace",
                "path" => "replace_test.txt",
                "old_str" => "NonExistent",
                "new_str" => "Something"
            ))
            @test occursin("Error", result["content"][1]["text"])
            @test occursin("not found", result["content"][1]["text"])
        end
        
        @testset "Create with subdirectory" begin
            # Create file in subdirectory (should create the directory)
            result = execute(editor, Dict(
                "command" => "create",
                "path" => "subdir/nested/file.txt",
                "file_text" => "Nested content"
            ))
            
            @test haskey(result, "content")
            @test occursin("File created successfully", result["content"][1]["text"])
            
            # Verify file and directories were created
            @test isdir(joinpath(tmpdir, "subdir"))
            @test isdir(joinpath(tmpdir, "subdir", "nested"))
            @test isfile(joinpath(tmpdir, "subdir", "nested", "file.txt"))
        end
        
        @testset "Error handling" begin
            # Missing path
            result = execute(editor, Dict("command" => "view"))
            @test occursin("Error", result["content"][1]["text"])
            @test occursin("No path", result["content"][1]["text"])
            
            # Invalid command
            result = execute(editor, Dict(
                "command" => "invalid",
                "path" => "test.txt"
            ))
            @test occursin("Error", result["content"][1]["text"])
            @test occursin("Unknown command", result["content"][1]["text"])
            
            # Missing parameters for str_replace
            result = execute(editor, Dict(
                "command" => "str_replace",
                "path" => "test.txt",
                "old_str" => "something"
                # missing new_str
            ))
            @test occursin("Error", result["content"][1]["text"])
            @test occursin("required", result["content"][1]["text"])
        end
    end
end