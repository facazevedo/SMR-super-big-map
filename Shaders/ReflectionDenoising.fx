#include "Common.fh"
#include "SbmReflectionMark.fh"

DefineTexture2D(PS, ReflectionMap, 0, FLOAT4_FMT);

DEFINE_VERT_INP
	FULLSCREEN_QUAD_ATTRIBUTES
ENDDEF_VERT_INP

DEFINE_INTERPS
ENDDEF_INTERPS

BEGIN_VERT_SHADER
	VERT_POS = float4(VATTR(pos).xy, 0.0f, 1.0f);
END_VERT_SHADER

DEFINE_FRAG_OUTP
	DECL_FO_RT(PROJ_MAIN_RT_FMT, final, 0);
ENDDEF_FRAG_OUTP

#define KNN_RADIUS 2.0f
#define KNN_AREA ((2 * KNN_RADIUS + 1) * (2 * KNN_RADIUS + 1))
#define INV_KNN_WINDOW_AREA (1.0f / KNN_AREA)
#define KNN_WEIGHT_THRESHOLD 0.02f
#define KNN_LERP_THRESHOLD 0.79f

BEGIN_FRAG_SHADER
	float4 own_raw = tex2DFetch(ReflectionMap, int2(FRAG_POS));
	bool own_marked = SbmIsMarked(own_raw.xyz);
	own_raw.xyz = SbmDecodeMark(own_raw.xyz);
	float4 reflection = saturate(own_raw);
	reflection.x = min(reflection.x, 2.0f);
	reflection.y = min(reflection.y, 2.0f);
	reflection.z = min(reflection.z, 2.0f);
	float3 base_color = reflection.xyz;
	float mip_to_use = reflection.w;
	float noise = 0.32f;
	
	float count = 0.0f;
	float total_knn_weight = 0.0f;
	float3 final_color = float3(0.0f, 0.0f, 0.0f);
	for (float y = -KNN_RADIUS; y <= KNN_RADIUS; y++)
	{
		for (float x = -KNN_RADIUS; x <= KNN_RADIUS; x++)
		{
			float3 curr_color = SbmDecodeMark(tex2DFetch(ReflectionMap, int2(FRAG_POS.x + x, FRAG_POS.y + y)).xyz);
			curr_color.x = min(curr_color.x, 2.0f);
			curr_color.y = min(curr_color.y, 2.0f);
			curr_color.z = min(curr_color.z, 2.0f);
			float color_distance = length(base_color - curr_color);
			float knn_weight = exp(-(color_distance * noise + (x*x + y*y) * INV_KNN_WINDOW_AREA));

			final_color += curr_color * knn_weight;
			total_knn_weight += knn_weight;
			count += (knn_weight > KNN_WEIGHT_THRESHOLD) ? INV_KNN_WINDOW_AREA : 0;
		}
	}
	
	total_knn_weight = 1.0f / total_knn_weight;
	final_color *= total_knn_weight;

	float lerp_val = (count > KNN_LERP_THRESHOLD) ? 0.1f : 0.6;

	final_color = lerp(final_color, base_color, lerp_val);
	FRAG_OUT(final) = gvec4(own_marked ? SbmEncodeMark(final_color) : final_color);
END_FRAG_SHADER

#ifdef RENDER_STATE
	DEPTH = False;
	STENCIL = False;
	BLEND = False;
	WRITE_MASK = 15;
	SLOTS_LAYOUT = MiscGraphics;
#endif

