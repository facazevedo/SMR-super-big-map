#define RESOURCE_REGISTERS
#define regDepthMap 0

#include "Common.fh"
#include "SbmReflectionMark.fh"
#include "GBufferUtils.fh"
#include "Raytracing.fh"

struct RaySampleData {
	int x, y;
	int parentIndex;
	int level;
	int4 childIndices;
};

BEGIN_CBUFFER(MainParams, 0)
	DECL_UNIFORM(float2, RenderTargetSize)
	DECL_UNIFORM(float, ScaleCoef)
	DECL_UNIFORM(float, SkipPixels)

	DECL_UNIFORM(float, NumDepthMips)
	DECL_UNIFORM(int,   NumReflectionMips)
	DECL_UNIFORM(float, ReflectionMipBias)
	DECL_UNIFORM(int,   PassBehindPixelsMax)

	DECL_UNIFORM(float, ThresholdParentDistance)
	DECL_UNIFORM(float, ThresholdCosNormalAngle)
	DECL_UNIFORM(float, ZThickness)
	DECL_UNIFORM(float, ZThicknessCoef)

	DECL_UNIFORM_ARR(RaySampleData, RaySamples, 64)

	DECL_UNIFORM(int,   PassBehindPixelsMin)
	DECL_UNIFORM(float, PassBehindRoughnessMin)
	DECL_UNIFORM(float, PassBehindRoughnessMax)
	DECL_UNIFORM(float, EnvLodBias)
	DECL_UNIFORM(int,   FrameIndex)
END_CBUFFER

#define maxDistance 3000.0f
#define stride 10.0f
#define maxSteps 200.0f
#define strideZCutoff 0.01


DefineTexture2D(CS, BaseDepthMap, 1, FLOAT_FMT);
DefineTexture2D(CS, ColorMap, 2, FLOAT3_FMT);
DefineTexture2D(CS, GBuffer0, 3, SRV_FMT(PROJ_GB0_RT_FMT));
DefineTexture2D(CS, GBuffer2, 4, SRV_FMT(PROJ_GB2_RT_FMT));
DefineTexture2D(CS, GBuffer3, 5, SRV_FMT(PROJ_GB3_RT_FMT));
DefineTextureCube(CS, ExteriorEnvMap, 6, FLOAT3_FMT);
DefineTextureCube(CS, InteriorEnvMap, 7, FLOAT3_FMT);

DefineRWTexture2D(Reflections,  0, FLOAT3_FMT, float_r11g11b10, NON_COHERENT);
DefineRWStructBuffer(CS, TileCounter, 1, int, COHERENT);

#if defined(REFLECT_IMPORTANCE_SAMPLE)
DefineRWTexture2D(RayLengths,   2, FLOAT_FMT,  float16_c1,      NON_COHERENT);
#endif

 //http://jcgt.org/published/0007/04/01/paper.pdf by Eric Heitz
float3 SampleGGXVNDF(float3 Ve, float alpha_x, float alpha_y, float U1, float U2) {
	//transforming the view direction to the hemisphere configuration
	float3 Vh = normalize(float3(alpha_x * Ve.x, alpha_y * Ve.y, Ve.z));

	//orthonormal basis (with special case if cross product is zero)
	float lensq = Vh.x * Vh.x + Vh.y * Vh.y;
	float3 T1 = lensq > 0 ? float3(-Vh.y, Vh.x, 0) * rsqrt(lensq) : float3(1, 0, 0);
	float3 T2 = cross(Vh, T1);
	//parameterization of the projected area
	float r = sqrt(U1);
	float phi = 2.0 * PI * U2;
	float t1 = r * cos(phi);
	float t2 = r * sin(phi);
	float s = 0.5 * (1.0 + Vh.z);
	t2 = (1.0 - s) * sqrt(1.0 - t1 * t1) + s * t2;
	//reprojection onto hemisphere
	float3 Nh = t1 * T1 + t2 * T2 + sqrt(max(0.0, 1.0 - t1 * t1 - t2 * t2)) * Vh;
	//transforming the normal back to the ellipsoid configuration
	float3 Ne = normalize(float3(alpha_x * Nh.x, alpha_y * Nh.y, max(0.0, Nh.z)));
	return Ne;
}

float3x3 CreateTBN(float3 N) {
	float3 U;
	if (abs(N.z) > 0.0) {
		float k = sqrt(N.y * N.y + N.z * N.z);
		U.x = 0.0; U.y = -N.z / k; U.z = N.y / k;
	}
	else {
		float k = sqrt(N.x * N.x + N.y * N.y);
		U.x = N.y / k; U.y = -N.x / k; U.z = 0.0;
	}

	float3x3 TBN;
	TBN[0] = U;
	TBN[1] = cross(N, U);
	TBN[2] = N;
	return transpose(TBN);
}
//
float3 ImportanceSampleReflectionRay(int2 frag_pos, float roughness, float3 csRayOrigin, float3 normal, float3 csRayDirection)
{
	if (roughness > 0.001f) {
		float alpha = roughness * roughness;

		// Spatial component: Interleaved Gradient Noise (Jorge Jimenez 2014)
		float ign_u1 = frac(52.9829189f * frac(0.06711056f * float(frag_pos.x)      + 0.00583715f * float(frag_pos.y)));
		float ign_u2 = frac(52.9829189f * frac(0.06711056f * float(frag_pos.x + 37) + 0.00583715f * float(frag_pos.y + 17)));
		float u1 = frac(ign_u1 + float(FrameIndex) * 0.6180339887f); // golden ratio
		float u2 = frac(ign_u2 + float(FrameIndex) * 0.7548776662f); // 1/phi^2 (silver ratio)

		float3x3 tbn     = CreateTBN(normal);
		float3x3 inv_tbn = transpose(tbn);

		// View direction in tangent space
		float3 V_ts = TRANSFORM3(normalize(-csRayOrigin), inv_tbn);

		// Sample half-vector and reflect
		float3 H_ts = SampleGGXVNDF(V_ts, alpha, alpha, u1,u2);
		float3 R_ts = reflect(-V_ts, H_ts);

		// Only update if the sampled ray stays above the surface fall back to perfect specular.
		if (R_ts.z > 0.0f)
			csRayDirection = normalize(TRANSFORM3(R_ts, tbn));
	}
	return csRayDirection;
}

 float4 ComputeReflection(int2 frag_pos, float3 view, float3 normal, float roughness, float is_exterior)
 {
	// empirical constant to match the look of environment map reflections at low roughness
	const float envLodBias = EnvLodBias;


#if defined(USE_HYPERBOLIC_DEPTH)
	float depth = tex2DFetch(BaseDepthMap, int2(frag_pos * ScaleCoef)).x;
	depth = LinearizeDepth(depth);
#elif defined(TRACE_HIZ)
	float depth = tex2DFetch(LinearDepthMap, int2(frag_pos)).x;
#else
	float depth = tex2DFetch(BaseDepthMap, int2(frag_pos * ScaleCoef)).x;
#endif

	if (depth > FrustumFarZ - 1e-2f)
	{
		float3 env = texCubeLod(ExteriorEnvMap, view, envLodBias, TrilinearClampCS) * LMExtEnvExposure;
		return float4(env,0.0f);
	}
	else
	{
		float3 nnV = view * depth;

		float3 csRayOrigin = TRANSFORM3(nnV, MAT4TO3(View));
		float3 csRayDirection = normalize(reflect(csRayOrigin, normal));

#if defined(REFLECT_IMPORTANCE_SAMPLE)
		csRayDirection = ImportanceSampleReflectionRay(frag_pos, roughness, csRayOrigin, normal, csRayDirection);
#endif // REFLECT_IMPORTANCE_SAMPLE

		bool found;
		float2 hit_pixel;
		float3 hit_point;
		float step_count;
		float hit_depth = -1;

#if defined(TRACE_HIZ) && !defined(USE_HYPERBOLIC_DEPTH)
		int passBehindPixels = PassBehindPixelsMax;
		if (PassBehindPixelsMin < PassBehindPixelsMax) {
			float coef = (roughness - PassBehindRoughnessMin) / (PassBehindRoughnessMax - PassBehindRoughnessMin);
			passBehindPixels = int(round(lerp(PassBehindPixelsMin, PassBehindPixelsMax, saturate(coef))));
		}

		found = TraceScreenSpaceRayHiZ(csRayOrigin, csRayDirection, RenderTargetSize / ScaleCoef,
			maxDistance, step_count, 1024, ZThickness, ZThicknessCoef, NumDepthMips, SkipPixels, passBehindPixels, hit_pixel, hit_depth);
#else
		found = TraceScreenSpaceRay(csRayOrigin, csRayDirection, 0.0f, RenderTargetSize / SELECT_HYPERBOLIC_DEPTH(1.0f, ScaleCoef),
			maxDistance, stride, maxSteps, step_count, ZThickness, strideZCutoff, hit_pixel, hit_point);
#endif
		hit_pixel *= SELECT_HYPERBOLIC_DEPTH(1.0f, ScaleCoef);

#if defined(REFLECTION_DEBUG) && defined(REFLECTION_ITERATIONS)
		float stepMax = maxSteps;
		float stepsRelative = saturate(step_count / stepMax);
		return float4(0.0, stepsRelative, 0.0, 0.0);
#else
		BRANCH
		if (!found || any(lessThan(hit_pixel, broadcast2(0.0))) || any(greaterThanEqual(hit_pixel, RenderTargetSize)))
		{
			float3 env = EnvSpecularColor * EnvSpecularMultiplier * lerp(LMIntEnvExposure, LMExtEnvExposure, is_exterior);
			BRANCH
			if (is_exterior > 0.5f)
				env *= texCubeLod(ExteriorEnvMap, TRANSFORM3(csRayDirection, MAT4TO3(ViewInverse)), envLodBias, TrilinearClampCS);
			else
				env *= texCubeLod(InteriorEnvMap, TRANSFORM3(csRayDirection, MAT4TO3(ViewInverse)), envLodBias, TrilinearClampCS);
#if defined(REFLECTION_DEBUG)
			env = float3(1, 0, 1);
#endif
			return float4(env, 0.0f);

		}
		else
		{
			float2 pix_tc = (floor(hit_pixel) + ScaleCoef * 0.5) / RenderTargetSize;
			float3 color = tex2DLod(ColorMap, pix_tc, 0, LinearClampCS).xyz;
			color = LimitLuminance(color, ReflectionPeakLuminance);

			// Reconstruct view-space hit position to compute reflected ray length.
			// Denoiser adds this to surface depth for parallax (hit-point) reprojection.
#if defined(TRACE_HIZ) && !defined(USE_HYPERBOLIC_DEPTH)
			float2 hit_uv    = (floor(hit_pixel) + 0.5f) / RenderTargetSize;
			float3 h0_hit    = lerp(ScreenToWorld[0], ScreenToWorld[2], hit_uv.x).xyz;
			float3 h1_hit    = lerp(ScreenToWorld[1], ScreenToWorld[3], hit_uv.x).xyz;
			float3 hit_vs    = TRANSFORM3(lerp(h1_hit, h0_hit, hit_uv.y) * hit_depth, MAT4TO3(View));
			float  ray_length = length(hit_vs - csRayOrigin);
#else
			float  ray_length = length(hit_point - csRayOrigin);
#endif
			return float4(color, ray_length);
		}
#endif
	}
}

// SBM: see SbmReflectionMark.fh.
float3 SbmStoreValue(const int2 pixPos, float3 rgb)
{
	BRANCH
	if (!SbmMarkingOn())
		return rgb;
	float3 own_color = tex2DFetch(ColorMap, int2(pixPos * ScaleCoef)).xyz;
	return all(equal(own_color, broadcast3(0.0f))) ? SbmEncodeMark(rgb) : rgb;
}

float4 GetPixReflection(const int2 pixPos, const uint2 outSize)
{
	MaterialData material_data = DecodeGBuffers(
		tex2DFetch(GBuffer0, int2(pixPos * ScaleCoef)),
		broadcast4(0.0f),
		tex2DFetch(GBuffer2, int2(pixPos * ScaleCoef)),
		tex2DFetch(GBuffer3, int2(pixPos * ScaleCoef)),
		DECODE_VIEWSPACE_NORMAL
	);

	float2 pos = (pixPos + 0.5) / outSize;
	float3 h0 = lerp(ScreenToWorld[0], ScreenToWorld[2], pos.x).xyz;
	float3 h1 = lerp(ScreenToWorld[1], ScreenToWorld[3], pos.x).xyz;
	float3 view = lerp(h1, h0, pos.y);

	return ComputeReflection(pixPos, view, material_data.normal, material_data.roughness, material_data.is_exterior);
}


#define TILE_SIZE 8


#if defined(REFLECT_RAYS)

#define MAX_RAYS (TILE_SIZE * TILE_SIZE * 2)

groupshared int TileIndex;
groupshared int BeginRays, EndRays;
groupshared int BeginTiles, EndTiles;
groupshared uint GroupRays[MAX_RAYS];

groupshared uint TilesHasParentMask[TILE_SIZE * TILE_SIZE][2];
groupshared int Tiles[TILE_SIZE * TILE_SIZE];

#if defined(REFLECT_IMPORTANCE_SAMPLE)
groupshared float4 Samples[1 + 4 + 16];
#else 
groupshared float3 Samples[1 + 4 + 16];

#endif

void SetHasParent(int tileIndex, int pixIndex, bool value)
{
	tileIndex = tileIndex % (TILE_SIZE * TILE_SIZE);
	const uint ind = pixIndex / 32;
	const uint mask = 1u << (pixIndex % 32);
	if (value)
		InterlockedOr(TilesHasParentMask[tileIndex][ind], mask);
	else
		InterlockedAnd(TilesHasParentMask[tileIndex][ind], ~mask);
}

bool GetHasParent(int tileIndex, int pixIndex)
{
	tileIndex = tileIndex % (TILE_SIZE * TILE_SIZE);
	const uint ind = pixIndex / 32;
	const uint mask = 1u << (pixIndex % 32);
	return (TilesHasParentMask[tileIndex][ind] & mask) != 0;
}

bool GetAnyHasParent(int tileIndex)
{
	tileIndex = tileIndex % (TILE_SIZE * TILE_SIZE);
	return TilesHasParentMask[tileIndex][0] != 0u || TilesHasParentMask[tileIndex][1] != 0u;
}

void GetPixPositions(const int2 tilePos, const uint2 outSize, const int pixIndex, out int2 pixPosOut, out int parentIndexOut, out int2 parentPosOut)
{
	pixPosOut = parentPosOut = int2(-1, -1);
	parentIndexOut = -1;
	const int2 pixOffset = int2(RaySamples[pixIndex].x, RaySamples[pixIndex].y);
	const int2 pixPos = tilePos + pixOffset;

	if (any(greaterThanEqual(pixPos, int2(outSize))))
		return;

	pixPosOut = pixPos;

	const int parentIndex = RaySamples[pixIndex].parentIndex;
	if (parentIndex < 0)
		return;

	const int2 parentOffset = int2(RaySamples[parentIndex].x, RaySamples[parentIndex].y);
	const int2 parentPos = tilePos + parentOffset;
	if (any(greaterThanEqual(parentPos, int2(outSize))))
		return;

	float roughness = DecodeGBuffers(
		broadcast4(0.0f),
		broadcast4(0.0f),
		tex2DFetch(GBuffer2, int2(pixPos * ScaleCoef)),
		0u
	).roughness;

	const int2 parentDistance = abs(parentPos - pixPos);
	// the mip calculation mirrors the one in ApplyReflections.fx
	float lod = roughness * (NumReflectionMips - 1);
	lod = max(0, lod - ReflectionMipBias);
	float dist = max(parentDistance.x, parentDistance.y) / pow(2, lod);

	if (dist > ThresholdParentDistance)
		return;

	if (ThresholdCosNormalAngle >= -1) {
		float3 pixNormal = DecodeGBuffers(
			tex2DFetch(GBuffer0, int2(pixPos * ScaleCoef)),
			broadcast4(0.0f),
			broadcast4(0.0f),
			tex2DFetch(GBuffer3, int2(pixPos * ScaleCoef))
		).normal;

		float3 parentNormal = DecodeGBuffers(
			tex2DFetch(GBuffer0, int2(parentPos * ScaleCoef)),
			broadcast4(0.0f),
			broadcast4(0.0f),
			tex2DFetch(GBuffer3, int2(parentPos * ScaleCoef))
		).normal;

		if (dot(pixNormal, parentNormal) < ThresholdCosNormalAngle * roughness)
			return;
	}

	parentPosOut = parentPos;
	parentIndexOut = parentIndex;
}

int ScatterTileRays(int startTile, int endRayIndex, uint2 outSize, uint numTilesX, int pixIndex)
{
	const uint tile = TILE_SIZE;

	AllMemoryBarrierWithGroupSync();

	int t = startTile;
	for (; t < EndTiles; ++t) {
		int tileIndex = Tiles[t % (tile * tile)];

		int tileEndRays = tileIndex & ((1 << 7) - 1);
		tileEndRays += BeginRays & ~(MAX_RAYS - 1);
		tileEndRays += (tileEndRays <= BeginRays) * MAX_RAYS;
		if (tileEndRays > endRayIndex)
			break;

		tileIndex >>= 7;
		int2 tilePos = int2(tileIndex % numTilesX, tileIndex / numTilesX) * tile;

		int2 pixPos = tilePos + int2(RaySamples[pixIndex].x, RaySamples[pixIndex].y);
		bool isActive = all(lessThan(int2(pixPos), outSize));
		bool hasParent = false;
		if (isActive) {
			hasParent = GetHasParent(t, pixIndex);

			if (!hasParent) {
				int4 pixChildren = RaySamples[pixIndex].childIndices;
				bool hasSamplingChildren =
					(pixChildren[0] >= 0 && GetHasParent(t, pixChildren[0])) ||
					(pixChildren[1] >= 0 && GetHasParent(t, pixChildren[1])) ||
					(pixChildren[2] >= 0 && GetHasParent(t, pixChildren[2])) ||
					(pixChildren[3] >= 0 && GetHasParent(t, pixChildren[3]));

				if (hasSamplingChildren)
				{
#if defined(REFLECT_IMPORTANCE_SAMPLE)
					Samples[pixIndex].xyz = RW_textureLoad(Reflections, pixPos);
					Samples[pixIndex].z   = RW_textureLoad(RayLengths, pixPos);
#else 
					Samples[pixIndex].xyz = RW_textureLoad(Reflections, pixPos);
#endif
				}
			}
		}

		GroupMemoryBarrierWithGroupSync();

		if (hasParent) {
			int parentIndex = RaySamples[pixIndex].parentIndex;
			if (GetHasParent(t, parentIndex)) {
				parentIndex = RaySamples[parentIndex].parentIndex;
				if (GetHasParent(t, parentIndex)) {
					parentIndex = RaySamples[parentIndex].parentIndex;
					if (GetHasParent(t, parentIndex))
						parentIndex = RaySamples[parentIndex].parentIndex;
				}
			}

#if defined(REFLECT_IMPORTANCE_SAMPLE)
			RW_textureStore(Reflections, pixPos, SbmStoreValue(pixPos, Samples[parentIndex].xyz));
			RW_textureStore(RayLengths, pixPos, Samples[parentIndex].w);
#else 
			RW_textureStore(Reflections, pixPos, SbmStoreValue(pixPos, Samples[parentIndex]));
#endif
		}

		GroupMemoryBarrierWithGroupSync();
	}

	return t;
}

void ReflectRay(int rayIndex, uint2 outSize, uint numTilesX)
{
	uint ray = GroupRays[rayIndex % MAX_RAYS];

	const uint rayPixIndex = ray & ((1 << 6) - 1);
	const uint rayTileIndex = ray >> 6;
	const int2 tilePos = int2(rayTileIndex % numTilesX, rayTileIndex / numTilesX) * TILE_SIZE;
	const int2 pixPos = tilePos + int2(RaySamples[rayPixIndex].x, RaySamples[rayPixIndex].y);

	float4 reflectionPlusLength = GetPixReflection(pixPos, outSize);
	RW_textureStore(Reflections, pixPos, SbmStoreValue(pixPos, reflectionPlusLength.xyz));

#if defined(REFLECT_IMPORTANCE_SAMPLE)
	RW_textureStore(RayLengths, pixPos, reflectionPlusLength.w);
#endif
}


BEGIN_COMPUTE_SHADER(TILE_SIZE, TILE_SIZE, 1)
	const uint tile = TILE_SIZE;

	const uint2 outSize = tex2DSize(Reflections);
	const uint2 numTiles = (outSize + tile - 1) / tile;
	const int pixIndex = GROUP_THREAD_ID.y * tile + GROUP_THREAD_ID.x;

	if (pixIndex == 0) {
		BeginRays = EndRays = 0;
		BeginTiles = EndTiles = 0;
	}

	while (true) {
		GroupMemoryBarrierWithGroupSync();

		if (pixIndex == 0) {
			InterlockedAdd(TileCounter[0], 1, TileIndex);
			if (TileIndex >= int(numTiles.x * numTiles.y)) {
				TileIndex = -1;
			} 
		}

		GroupMemoryBarrierWithGroupSync();

		if (TileIndex >= 0) {
			const int2 tilePos = int2(TileIndex % numTiles.x, TileIndex / numTiles.x) * tile;

			int parentIndex;
			int2 pixPos, parentPos;
			GetPixPositions(tilePos, outSize, pixIndex, pixPos, parentIndex, parentPos);

			SetHasParent(EndTiles, pixIndex, parentPos.x >= 0);

			if (pixPos.x >= 0 && parentPos.x < 0) {
				uint ray = pixIndex + (TileIndex << 6);
				int rayIndex;
				InterlockedAdd(EndRays, 1, rayIndex);

				GroupRays[rayIndex % MAX_RAYS] = ray;
			}

			GroupMemoryBarrierWithGroupSync();
			if (pixIndex == 0) {
				if (GetAnyHasParent(EndTiles)) {
					Tiles[EndTiles++ % (tile * tile)] = (TileIndex << 7) + (EndRays % MAX_RAYS);
				}
			}
		} else {
			// reflect the last rays
			int rayIndex = BeginRays + pixIndex;
			if (rayIndex < EndRays)
				ReflectRay(rayIndex, outSize, numTiles.x);

			// scatter all remaining tiles
			ScatterTileRays(BeginTiles, EndRays, outSize, numTiles.x, pixIndex);
			break;
		}

		if (EndRays - BeginRays >= int(tile * tile)) {
			int rayIndex = BeginRays + pixIndex;

			// reflect a full tile of rays
			ReflectRay(rayIndex, outSize, numTiles.x);

			// scatter results for the tiles that were fully processed with those rays
			int lastTile = ScatterTileRays(BeginTiles, BeginRays + tile * tile, outSize, numTiles.x, pixIndex);

			if (pixIndex == 0) {
				BeginRays += tile * tile;
				BeginTiles = lastTile;
			}
		}
	}
END_COMPUTE_SHADER

#elif defined(REFLECT_FULL)

BEGIN_COMPUTE_SHADER(REFLECT_TILE, REFLECT_TILE, 1)
	const uint2 outSize = tex2DSize(Reflections);
	const int2 pixPos = int2(DISPATCH_THREAD_ID.xy);

	if (any(greaterThanEqual(pixPos, int2(outSize))))
		return;

	float4 reflectionPlusLength = GetPixReflection(pixPos, outSize);
	RW_textureStore(Reflections, pixPos, SbmStoreValue(pixPos, reflectionPlusLength.xyz));
#if defined(REFLECT_IMPORTANCE_SAMPLE)
	RW_textureStore(RayLengths, pixPos, reflectionPlusLength.w);
#endif
END_COMPUTE_SHADER

#endif

#ifdef RENDER_STATE
	SLOTS_LAYOUT = MiscCompute;
#endif
