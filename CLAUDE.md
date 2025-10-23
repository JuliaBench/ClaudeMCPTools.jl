# Development Guidelines for ClaudeMCPTools.jl

## Shipping Code

When asked to "ship it" or after making changes:

1. Stage all changes: `git add -A`
2. Create a descriptive commit message
3. Run tests locally and make sure they pass: `julia --project=. -e 'using Pkg; Pkg.test()'`
4. Push to the repository: `git push origin master`
5. **IMPORTANT**: Monitor the GitHub Actions CI run
   - Use: `gh run list --repo JuliaComputing/ClaudeMCPTools.jl --branch master --limit 1` to find the run
   - Use: `gh run watch <run-id> --repo JuliaComputing/ClaudeMCPTools.jl --exit-status` to monitor it (can take up to 10 minutes)
   - If it fails, investigate and fix before considering the task complete

## Testing

Always run tests before pushing:
```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

## Package Structure

- `src/ClaudeMCPTools.jl` - Main module file
- `src/types.jl` - Core types and interfaces
- `src/server.jl` - MCP server implementation
- `src/tools/` - Individual tool implementations
  - `bash.jl` - Bash command execution tool
  - `str_replace_editor.jl` - File editing tool

## Adding New Tools

1. Create a new file in `src/tools/`
2. Define a struct that subtypes `MCPTool`
3. Implement `tool_schema(tool)` method
4. Implement `execute(tool, params)` method
5. Export the tool from the main module
6. Add tests in `test/`