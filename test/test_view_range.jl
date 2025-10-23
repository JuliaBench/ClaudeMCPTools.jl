@testset "view_range functionality" begin
    # Create a temporary test file
    test_dir = mktempdir()
    test_file = joinpath(test_dir, "test_view_range.txt")
    
    # Write test content
    test_lines = ["Line $i" for i in 1:20]
    write(test_file, join(test_lines, "\n"))
    
    tool = StrReplaceEditorTool(base_path=test_dir)
    
    @testset "Valid view_range operations" begin
        # Test viewing a specific range
        result = execute(tool, Dict(
            "command" => "view",
            "path" => "test_view_range.txt",
            "view_range" => [5, 10]
        ))
        @test !result["isError"]
        text = result["content"][1]["text"]
        @test occursin("view_range=[5, 10]", text)
        @test occursin("5\tLine 5", text)
        @test occursin("10\tLine 10", text)
        @test !occursin("4\tLine 4", text)
        @test !occursin("11\tLine 11", text)
        
        # Test viewing to end of file with -1
        result = execute(tool, Dict(
            "command" => "view",
            "path" => "test_view_range.txt",
            "view_range" => [18, -1]
        ))
        @test !result["isError"]
        text = result["content"][1]["text"]
        @test occursin("18\tLine 18", text)
        @test occursin("20\tLine 20", text)
        @test !occursin("17\tLine 17", text)
        
        # Test viewing a single line
        result = execute(tool, Dict(
            "command" => "view",
            "path" => "test_view_range.txt",
            "view_range" => [15, 15]
        ))
        @test !result["isError"]
        text = result["content"][1]["text"]
        @test occursin("15\tLine 15", text)
        @test !occursin("14\tLine 14", text)
        @test !occursin("16\tLine 16", text)
    end
    
    @testset "Invalid view_range operations" begin
        # Test with end before start
        result = execute(tool, Dict(
            "command" => "view",
            "path" => "test_view_range.txt",
            "view_range" => [10, 5]
        ))
        @test result["isError"]
        @test occursin("should be larger or equal than its first", result["content"][1]["text"])
        
        # Test with start line out of bounds
        result = execute(tool, Dict(
            "command" => "view",
            "path" => "test_view_range.txt",
            "view_range" => [0, 5]
        ))
        @test result["isError"]
        @test occursin("should be within the range", result["content"][1]["text"])
        
        # Test with end line out of bounds
        result = execute(tool, Dict(
            "command" => "view",
            "path" => "test_view_range.txt",
            "view_range" => [1, 50]
        ))
        @test result["isError"]
        @test occursin("should be smaller than the number of lines", result["content"][1]["text"])
        
        # Test with invalid array format
        result = execute(tool, Dict(
            "command" => "view",
            "path" => "test_view_range.txt",
            "view_range" => [5]  # Only one element
        ))
        @test result["isError"]
        @test occursin("should be a list of two integers", result["content"][1]["text"])
        
        # Test view_range on directory (not allowed)
        result = execute(tool, Dict(
            "command" => "view",
            "path" => ".",
            "view_range" => [1, 10]
        ))
        @test result["isError"]
        @test occursin("not allowed when path points to a directory", result["content"][1]["text"])
    end
    
    @testset "view_range with other commands" begin
        # view_range should be ignored for str_replace
        write(test_file, "old text\nmore text\nold text")
        result = execute(tool, Dict(
            "command" => "str_replace",
            "path" => "test_view_range.txt",
            "old_str" => "more text",
            "new_str" => "new text",
            "view_range" => [1, 2]  # Should be ignored
        ))
        @test !result["isError"]
        @test occursin("edited successfully", result["content"][1]["text"])
        
        # view_range should be ignored for create
        result = execute(tool, Dict(
            "command" => "create",
            "path" => "new_file.txt",
            "file_text" => "content",
            "view_range" => [1, 2]  # Should be ignored
        ))
        @test !result["isError"]
        @test occursin("File created successfully", result["content"][1]["text"])
    end
    
    # Clean up
    rm(test_dir, recursive=true)
end