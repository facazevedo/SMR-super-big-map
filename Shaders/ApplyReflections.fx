#define RESOURCE_REGISTERS
#define regBRDF                 7
#if defined(SKY_IS)
#	define regSkyViewLUT        8
#elif defined(ENV_IS)
#	define regEnvMap            8
#	define regMarkedEnvMap      9
#else
#	define regEnvSpecular       8
#	define regMarkedEnvSpecular 9
#endif
#define regExtinctionLUT        10
#define regAtmosphereParams     3

#include "Common.fh"
#include "SbmReflectionMark.fh"
#include "Bindless.fh"
#include "GBufferUtils.fh"
#include "Shading.fh"
#include "AtmosphereCommon.fh"
#include "Terrain.fh"
#include "VolumetricLightingCommon.fh"

#ifdef NRD_UNPACK
#include "NvidiaRealTime_Denoiser_EngineBindings.hlsli"
#endif

BEGIN_CBUFFER(MainParams, 0)
	DECL_UNIFORM(float2, RenderTargetParams)
	DECL_UNIFORM(float, ReflectionMipBias)
	DECL_UNIFORM(float, RoughnessMipScale)
	DECL_UNIFORM(float, EnvMip0Weight)
END_CBUFFER

DefineTexture2D(PS, ReflectionMap, 0, FLOAT3_FMT);
DefineTexture2D(PS, GBuffer0, 1, SRV_FMT(PROJ_GB0_RT_FMT));
DefineTexture2D(PS, GBuffer1, 2, SRV_FMT(PROJ_GB1_RT_FMT));
DefineTexture2D(PS, GBuffer2, 3, SRV_FMT(PROJ_GB2_RT_FMT));
DefineTexture2D(PS, GBuffer3, 4, SRV_FMT(PROJ_GB3_RT_FMT));
DefineTexture2D(PS, DepthMap, 5, FLOAT4_FMT);
DefineTexture2D(PS, OcclusionBuffer, 6, FLOAT_FMT);

DefineTexture2D(PS, ExtinctionLUT, regExtinctionLUT, FLOAT3_FMT);

DEFINE_VERT_INP
	FULLSCREEN_QUAD_ATTRIBUTES
ENDDEF_VERT_INP

DEFINE_INTERPS
	DECL_INTERP(float3, view);
ENDDEF_INTERPS

BEGIN_VERT_SHADER
	VERT_POS = float4(VATTR(pos).xy, 0.0f, 1.0f);
	INTERP(view) = TransformScreenToWorldView(VERTEX_ID);
END_VERT_SHADER

DEFINE_FRAG_OUTP
	DECL_FO_RT(PROJ_MAIN_RT_FMT, main, 0);
ENDDEF_FRAG_OUTP

BEGIN_FRAG_SHADER
	float depth = tex2DFetch(DepthMap, int2(FRAG_POS)).x;
	float linear_depth = LinearizeDepth(depth);
	if (IsSkyDepth(depth))
		DISCARD;

	MaterialData material_data = DecodeGBuffers(
		tex2DFetch(GBuffer0, int2(FRAG_POS)),
		tex2DFetch(GBuffer1, int2(FRAG_POS)),
		tex2DFetch(GBuffer2, int2(FRAG_POS)),
		tex2DFetch(GBuffer3, int2(FRAG_POS))
	);

	float specular_multiplier = 1.0f;
	if (material_data.is_water || material_data.is_custom_specular)
	{
		specular_multiplier = material_data.self_ao;
		specular_multiplier *= TerrainWaterMinimumDepth * 0.1;
		specular_multiplier *= TerrainWaterAbsorptionCoef *100;
		material_data.self_ao = 1.0f;
	}

	// the mip level calculation needs to match the one in GetPixPositions() in Reflections.fx
	float lod = material_data.roughness * RoughnessMipScale * (tex2DSize(ReflectionMap, 0).z - 1);
	lod = max(0, lod - ReflectionMipBias);
	float2 screen = CalculateAdjustedTexCoord(FRAG_POS, RenderTargetParams);
	// SBM: a pixel whose own reflection entry is marked is fully covered by the underground
	// darkness; reflections must add nothing to it. Level 0 keeps marked entries, so while marks
	// can exist any sampling that touches level 0 decodes the four texels itself.
	int2 sbm_size = tex2DSize(ReflectionMap, 0).xy;
	float2 sbm_p = screen * sbm_size - 0.5f;
	int2 sbm_p0 = clamp(int2(floor(sbm_p)), int2(0, 0), sbm_size - 1);
	int2 sbm_p1 = clamp(sbm_p0 + 1, int2(0, 0), sbm_size - 1);
	float2 sbm_f = saturate(sbm_p - floor(sbm_p));
	int2 sbm_own = clamp(int2(screen * sbm_size), int2(0, 0), sbm_size - 1);
	if (SbmIsMarked(tex2DFetchLod(ReflectionMap, sbm_own, 0).xyz))
		DISCARD;
	float3 sbm_l0 = lerp(
		lerp(SbmDecodeMark(tex2DFetchLod(ReflectionMap, int2(sbm_p0.x, sbm_p0.y), 0).xyz),
			SbmDecodeMark(tex2DFetchLod(ReflectionMap, int2(sbm_p1.x, sbm_p0.y), 0).xyz), sbm_f.x),
		lerp(SbmDecodeMark(tex2DFetchLod(ReflectionMap, int2(sbm_p0.x, sbm_p1.y), 0).xyz),
			SbmDecodeMark(tex2DFetchLod(ReflectionMap, int2(sbm_p1.x, sbm_p1.y), 0).xyz), sbm_f.x), sbm_f.y);
	float3 new_env_specular_0 = SbmMarkingOn() && lod < 1.0f
		? lerp(sbm_l0, tex2DLod(ReflectionMap, screen, 1, TrilinearClampPS).xyz, lod)
		: tex2DLod(ReflectionMap, screen, lod, TrilinearClampPS).xyz;
#ifdef NRD_UNPACK
	new_env_specular_0 = REBLUR_BackEnd_UnpackRadianceAndNormHitDist(float4(new_env_specular_0, 0)).xyz;
#endif
	if (EnvMip0Weight > 0) {
		float3 new_env_specular_lod_0 = SbmMarkingOn() ? sbm_l0 : tex2DLod(ReflectionMap, screen, 0, TrilinearClampPS).xyz;
#ifdef NRD_UNPACK
		new_env_specular_lod_0 = REBLUR_BackEnd_UnpackRadianceAndNormHitDist(float4(new_env_specular_lod_0, 0)).xyz;
#endif
		new_env_specular_0 = lerp(new_env_specular_0, new_env_specular_lod_0, EnvMip0Weight);
	}

	float translucent = material_data.metallic;
	if (material_data.is_translucent)
		material_data.metallic = 0.0f;

	material_data.base_color.xyz = LightModelDesatBaseColor(material_data.base_color.xyz);
	material_data.specular_color = getSpecularColor(material_data.base_color.xyz, material_data.metallic);

	float3 V = normalize(INTERP(view));
	float3 RV = reflect(V, material_data.normal);
	float NoV = -dot(material_data.normal, V);

	float3 nnV = INTERP(view) * linear_depth;
	float3 wpos = EyePosWorld + nnV;

	float3 old_env_specular;
	ComputeEnvSpecular(old_env_specular, material_data, NoV, RV, material_data.is_exterior);

	if (material_data.is_water)
	{
		new_env_specular_0 *= Linear2Gamma(TerrainWaterColor) *2;
		old_env_specular *= Linear2Gamma(TerrainWaterColor) *2;
	}	

	old_env_specular *= specular_multiplier;

	float2 brdf = tex2D(Brdf, float2(NoV, material_data.roughness), LinearClampPS);
	float3 new_env_specular = specular_multiplier * new_env_specular_0 * (material_data.specular_color * brdf.x + brdf.y);
	
	float ao = material_data.self_ao;
	if (material_data.is_water)
	{
		ao = 1.0;
	}
	else
	{
		if ((EnabledFeatures & AMBIENT_OCCLUSION_ENABLED) != 0)
			ao = min(tex2DFetch(OcclusionBuffer, int2(FRAG_POS)), ao);
		ao = pow(max(ao, 1.0e-10), AmbientOcclusionIntensity);
	}
	
	float3 extinction = GetAerialPerspectiveExtinction(
		TEXTURE_ARG(ExtinctionLUT), LinearClampPS,
		linear_depth, V
	);
	extinction *= GetVolumetricFog(FRAG_POS, linear_depth).Transmittance;

	FRAG_OUT(main) = gvec4(
#if defined(APPLY_DEBUG)
		tex2DLod(ReflectionMap, screen, lod, TrilinearClampPS).xyz
#else
		(new_env_specular - old_env_specular) * computeSpecOcclusion(NoV, ao, material_data.roughness) * extinction
#endif
	);
END_FRAG_SHADER

#ifdef RENDER_STATE
	DEPTH = False;
	STENCIL = False;
	BLEND = True;
#if defined(APPLY_DEBUG)
	BLEND_SRC = One;
	BLEND_DST = Zero;
#else
	BLEND_SRC = One;
	BLEND_DST = One;
#endif
	BLEND_FUNC = Add;
	WRITE_MASK = 7;
	SLOTS_LAYOUT = MiscGraphics;
#endif