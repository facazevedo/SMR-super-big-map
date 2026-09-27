Zero-byte files named after the compiled-shader cache entries (ShaderCached3d12.fpk) of
Reflections.fx, ReflectionDenoising.fx, ReflectionConvolution.fx and ApplyReflections.fx.
Mounted over the game's ShaderCache path they make those entries fail to load, so the engine
compiles the mod's Shaders/ sources instead. See Code/sbm_underground_darkness.lua.
