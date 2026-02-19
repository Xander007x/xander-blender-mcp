# xander-blender-mcp

Self-hosted Blender MCP server for AI-driven 3D modeling, integrated with the [llm-cluster](https://github.com/Xander007x/llm-cluster) orchestrator.

Uses the [poly-mcp/Blender-MCP-Server](https://github.com/poly-mcp/Blender-MCP-Server) addon (51 tools) with a lightweight `polymcp_toolkit` shim — **zero cloud dependencies**.

## Architecture

```
VS Code ←─stdio─→ Orchestrator (Machine 1, RTX 5090)
                      │
                      ├── Ollama (qwen3:32b) → generates Blender tool call plans
                      ├── Blender MCP (localhost:8000) → executes 3D operations
                      │     └── 51 tools: objects, materials, lighting, animation,
                      │         physics, rendering, import/export, geometry nodes
                      │
                      ├── Machine 2 (RTX 3090 Ti)
                      │     └── llama3.2-vision:11b → interprets reference images
                      │
                      └── Machine 3 (CPU, 64GB RAM)
                            └── Excalidraw (xander-draw-mcp) → 2D diagrams
```

## Setup (Machine 1)

### Prerequisites
- [Blender 3.0+](https://www.blender.org/download/) (4.x recommended)
- PowerShell 7+

### Install

```powershell
git clone https://github.com/Xander007x/xander-blender-mcp.git
cd xander-blender-mcp
.\scripts\setup.ps1
```

The setup script:
1. Finds your Blender installation
2. Downloads the poly-mcp addon from GitHub
3. Installs Python dependencies (FastAPI, uvicorn, etc.) into Blender's Python
4. Installs our `polymcp_toolkit` shim (replaces the full PolyMCP package)
5. Copies the addon + auto-start script into Blender's user directories

### Start

```powershell
.\scripts\start.ps1
```

Or just launch Blender normally — the server auto-starts on port 8000.

## API

Once running, the Blender MCP server exposes:

| Endpoint | Description |
|----------|-------------|
| `GET /health` | Server health check |
| `GET /docs` | Interactive API documentation |
| `GET /mcp/list_tools` | List all 51 available tools |
| `POST /mcp/invoke/{tool_name}` | Invoke a tool with JSON parameters |

### Example

```bash
# Create a red cube
curl -X POST http://localhost:8000/mcp/invoke/create_mesh_object \
  -H "Content-Type: application/json" \
  -d '{"primitive_type": "cube", "size": 2, "location": [0, 0, 1], "name": "MyCube"}'

# Add a material
curl -X POST http://localhost:8000/mcp/invoke/create_material \
  -H "Content-Type: application/json" \
  -d '{"name": "Red", "base_color": [1, 0, 0, 1], "roughness": 0.5}'

# Assign it
curl -X POST http://localhost:8000/mcp/invoke/assign_material \
  -H "Content-Type: application/json" \
  -d '{"object_name": "MyCube", "material_name": "Red"}'

# Render
curl -X POST http://localhost:8000/mcp/invoke/render_image \
  -H "Content-Type: application/json" \
  -d '{"return_base64": true}'
```

## Available Tools (51)

| Category | Tools |
|----------|-------|
| **Object Creation** | `create_mesh_object`, `create_curve_object`, `create_text_object` |
| **Manipulation** | `transform_object`, `duplicate_object`, `delete_objects` |
| **Modifiers** | `add_modifier`, `apply_modifier` |
| **Materials** | `create_material`, `assign_material`, `create_procedural_material`, `create_shader_node_tree` |
| **Lighting** | `create_light` |
| **Camera** | `create_camera` |
| **Animation** | `create_keyframe` |
| **Rendering** | `configure_render_settings`, `render_image` |
| **Physics** | `setup_rigid_body`, `add_cloth_simulation`, `setup_fluid_simulation`, `add_fluid_flow` |
| **Geometry Nodes** | `add_geometry_nodes`, `create_procedural_geometry` |
| **UV/Textures** | `unwrap_uv`, `add_texture_paint_slots` |
| **Batch Ops** | `batch_create_objects`, `batch_transform` |
| **Templates** | `create_from_template` (character, vehicle, building, tree) |
| **Scene** | `get_scene_info`, `clear_scene`, `quick_scene_setup`, `create_hdri_environment` |
| **File I/O** | `import_file`, `export_file`, `save_blend_file` |
| **Advanced** | `boolean_operation`, `create_grease_pencil_drawing`, `optimize_scene` |
| **Spatial** | `get_object_position`, `calculate_position_relative_to`, `get_all_objects_positions`, `find_empty_space`, `align_objects_in_grid` |
| **VLM** | `capture_viewport_image`, `analyze_spatial_layout`, `verify_last_operation`, `set_optimal_camera_for_all`, `auto_arrange_objects` |

## Orchestrator Integration

The [llm-cluster orchestrator](https://github.com/Xander007x/llm-cluster) adds these high-level tools:

| Tool | Description |
|------|-------------|
| `blender` | Natural language → LLM plans and executes Blender MCP tool calls |
| `blender_render` | Render the current scene, optionally return base64 image |
| `blender_export` | Export to .fbx, .gltf, .obj, .blend |
| `blender_scene` | Get current scene info (objects, materials, stats) |
| `blender_clear` | Clear the Blender scene |
| `blender_status` | Check if Blender MCP server is running |

### Example via Orchestrator

```
User: "Create a simple house with a red roof and render it"

Orchestrator:
  1. qwen3:32b plans the tool sequence
  2. Calls Blender MCP: create_mesh_object (house body)
  3. Calls Blender MCP: create_mesh_object (roof cone)
  4. Calls Blender MCP: create_material (wall paint)
  5. Calls Blender MCP: create_material (red roof)
  6. Calls Blender MCP: assign_material × 2
  7. Calls Blender MCP: quick_scene_setup (product_viz lighting)
  8. Calls Blender MCP: render_image (base64)
  → Returns rendered image
```

## polymcp_toolkit Shim

This repo includes a lightweight `polymcp_toolkit.py` that replaces the full [PolyMCP](https://github.com/llm-use/Polymcp) package. It provides the `expose_tools` function using plain FastAPI — no external agent framework needed. This keeps the stack fully local and dependency-minimal.

## License

MIT — addon source from [poly-mcp/Blender-MCP-Server](https://github.com/poly-mcp/Blender-MCP-Server) (MIT License).
