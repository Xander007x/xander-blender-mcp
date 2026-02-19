"""
Auto-start MCP Server — Blender startup script.

Place this file in Blender's user startup directory:
  %APPDATA%/Blender Foundation/Blender/<version>/scripts/startup/

It registers a one-shot timer that starts the Blender MCP server
3 seconds after Blender finishes initializing, giving all addons
time to register their operators.
"""

import bpy
import logging

logger = logging.getLogger("auto_start_mcp")


def _try_start_mcp_server():
    """Attempt to start the MCP server via the addon's operator."""
    try:
        # Check if the operator exists (addon is enabled)
        if hasattr(bpy.ops.mcp, "start_server"):
            bpy.ops.mcp.start_server()
            logger.info("[xander-blender-mcp] MCP Server auto-started on http://localhost:8000")
            print("[xander-blender-mcp] MCP Server auto-started on http://localhost:8000")
        else:
            logger.warning("[xander-blender-mcp] MCP addon not enabled — skipping auto-start")
            print("[xander-blender-mcp] MCP addon not enabled — skipping auto-start")
    except Exception as e:
        logger.error(f"[xander-blender-mcp] Failed to auto-start MCP server: {e}")
        print(f"[xander-blender-mcp] Failed to auto-start MCP server: {e}")

    return None  # Don't repeat the timer


def register():
    """Called by Blender when the startup script is loaded."""
    bpy.app.timers.register(_try_start_mcp_server, first_interval=3.0)


def unregister():
    """Called by Blender when the startup script is unloaded."""
    if bpy.app.timers.is_registered(_try_start_mcp_server):
        bpy.app.timers.unregister(_try_start_mcp_server)
