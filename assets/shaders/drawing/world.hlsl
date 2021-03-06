#pragma once

#include "world/chunkgen/noise.hlsl"

#define sun_col float3(1.0, 0.84, 0.75) * 2.5

float3 sample_sky(in Ray sun_ray, float3 nrm) {
    float sun_val = clamp((dot(nrm, sun_ray.nrm) - 0.9995) * 10000, 0, 10);
    float sky_val = clamp(dot(nrm, float3(0, 1, 0)) * 0.5 + 0.5, 0, 1);
    return sun_col * sun_val + lerp(float3(0.1, 0.2, 0.8) * 2, float3(0.15, 0.2, 0.54), pow(sky_val, 2));
}

float vertex_ao(float2 side, float corner) {
    // if (side.x == 1.0 && side.y == 1.0) return 1.0;
    return (side.x + side.y + max(corner, side.x * side.y)) / 3.0;
}

float4 voxel_ao(float4 side, float4 corner) {
    float4 ao;
    ao.x = vertex_ao(side.xy, corner.x);
    ao.y = vertex_ao(side.yz, corner.y);
    ao.z = vertex_ao(side.zw, corner.z);
    ao.w = vertex_ao(side.wx, corner.w);
    return 1.0 - ao;
}

void draw_world(
    in StructuredBuffer<Globals> globals,
    in StructuredBuffer<PlayerBuffer> player_buffer,
    in float2 uv, in uint3 pixel_i,
    in float2 subsamples, in float2 inv_subsamples,
    in float2 inv_frame_dim, in float aspect,
    in out float3 color, in out float depth) {
    float3 front;
    float3 right;
    float3 up;
    Ray cam_ray;

    // if (pixel_i.x < globals[0].frame_dim.x / 2) {
    //     front = mul(globals[0].viewproj_mat, float4(0, 0, 1, 0)).xyz;
    //     right = mul(globals[0].viewproj_mat, float4(1, 0, 0, 0)).xyz;
    //     up = mul(globals[0].viewproj_mat, float4(0, 1, 0, 0)).xyz;
    //     cam_ray.o = globals[0].pos.xyz;
    // } else {
    float4x4 view_mat = player_buffer[0].player.camera.view_mat;
    front = mul(view_mat, float4(0, 0, 1, 0)).xyz;
    right = mul(view_mat, float4(1, 0, 0, 0)).xyz;
    up = mul(view_mat, float4(0, 1, 0, 0)).xyz;
    cam_ray.o = player_buffer[0].player.pos.xyz;
    // }

    float3 view_intersection_pos = globals[0].pick_pos[0].xyz;
    int3 view_intersection_block_pos = int3(view_intersection_pos);

    Ray sun_ray;
    float sun_angle = 0.3;
    float sun_yz = -abs(cos(sun_angle)) * 2;
    sun_ray.nrm = normalize(float3(-sin(sun_angle) * 3, sun_yz, -0.2 * sun_yz));
    sun_ray.inv_nrm = 1 / sun_ray.nrm;

    for (uint yi = 0; yi < subsamples.y; ++yi) {
        for (uint xi = 0; xi < subsamples.x; ++xi) {
            float2 view_uv = (uv + inv_frame_dim * float2(xi, yi) * inv_subsamples) * globals[0].fov * float2(aspect, 1);
            float total_trace_dist = 0.0f;

#if LENS_TYPE == LENS_TYPE_FISHEYE
            {
                float r0 = atan2(view_uv.y, view_uv.x);
                float r1 = length(view_uv);
                if (r1 > 3.14159f)
                    continue;
                float3 r = float3(0, sin(r1), cos(r1));
                r = float3(cos(r0) * r.y, sin(r0) * r.y, r.z);
                cam_ray.nrm = normalize(front * r.z + right * r.x + up * r.y);
            }
#elif LENS_TYPE == LENS_TYPE_EQUIRECTANGULAR
            {
                float r0 = -view_uv.x;
                float r1 = view_uv.y;
                float cos_r0 = cos(r0), sin_r0 = sin(r0);
                float cos_r1 = cos(r1), sin_r1 = sin(r1);

                if (abs(r1) > 3.14159f * 0.5)
                    continue;
                if (abs(r0) > 3.14159f)
                    continue;

                float3x3 ry = float3x3(
                    +cos_r0, 0, -sin_r0,
                    0, 1, 0,
                    +cos_r0, 0, +cos_r0);
                float3x3 rx = float3x3(
                    1, 0, 0,
                    0, +cos_r1, +sin_r1,
                    0, -sin_r1, +cos_r1);

                float3 r = mul(ry, mul(rx, float3(0, 0, 1)));
                cam_ray.nrm = normalize(front * r.z + right * r.x + up * r.y);
            }
#else
            cam_ray.nrm = normalize(front + view_uv.x * right + view_uv.y * up);
#endif

            cam_ray.inv_nrm = 1 / cam_ray.nrm;
            float3 tint = float3(1, 1, 1);

            RayIntersection ray_chunk_intersection = trace_chunks(globals, cam_ray);
#if VISUALIZE_SUBGRID
            float3 intersection_pos = ray_chunk_intersection.pos;
            int3 intersection_block_pos = int3(intersection_pos);
            if (ray_chunk_intersection.hit) {
                BlockID block_id = load_block_id(globals, intersection_pos);
                float3 world_pos = intersection_block_pos;
                uint3 chunk_i = int3(world_pos / CHUNK_SIZE);
                uint3 in_chunk_p = int3(world_pos) - chunk_i * CHUNK_SIZE;
                uint3 x_i = in_chunk_p / 32;
                uint index = x_index<32>(x_i);
                uint mask = x_mask(x_i);

                uint lod = get_lod(globals, intersection_block_pos);
                switch (lod) {
                case 0: color += float3(0.00, 0.00, 0.00); break;
                case 1: color += float3(0.01, 0.01, 0.06); break;
                case 2: color += float3(0.01, 0.03, 0.10); break;
                case 3: color += float3(0.00, 0.10, 0.14); break;
                case 4: color += float3(0.00, 0.20, 0.15); break;
                case 5: color += float3(0.00, 0.30, 0.12); break;
                case 6: color += float3(0.00, 0.40, 0.04); break;
                case 7: color += float3(0.01, 0.70, 0.02); break;
                }

                float3 lod_block_uv = float3(fmod(intersection_pos, (1u << lod) * 0.5)) / (1u << lod) * 2;

                float3 b_uv = float3(int3(intersection_pos) % 64) / 64;
                BlockFace face_id;
                float2 tex_uv = float2(0, 0);
                float2 lod_uv = float2(0, 0);
                uint tex_id;
                get_texture_info(globals, ray_chunk_intersection, intersection_pos, block_id, tex_uv, face_id, tex_id);

                if (ray_chunk_intersection.nrm.x > 0.5) {
                    lod_uv = lod_block_uv.zy;
                    lod_uv.y = 1 - lod_uv.y;
                } else if (ray_chunk_intersection.nrm.x < -0.5) {
                    lod_uv = lod_block_uv.zy;
                    lod_uv = 1 - lod_uv;
                }
                if (ray_chunk_intersection.nrm.y > 0.5) {
                    lod_uv = lod_block_uv.xz;
                    lod_uv.x = 1 - lod_uv.x;
                } else if (ray_chunk_intersection.nrm.y < -0.5) {
                    lod_uv = lod_block_uv.xz;
                }
                if (ray_chunk_intersection.nrm.z > 0.5) {
                    lod_uv = lod_block_uv.xy;
                    lod_uv = 1 - lod_uv;
                } else if (ray_chunk_intersection.nrm.z < -0.5) {
                    lod_uv = lod_block_uv.xy;
                    lod_uv.y = 1 - lod_uv.y;
                }

                float2 tuv = abs(lod_uv - 0.5);
                float t_max = max(tuv.x, tuv.y);
                if (t_max < 0.5 - 0.5 / (1u << lod))
                    color += daxa::getTexture2DArray<float4>(globals[0].texture_index).Load(int4(tex_uv.x * 16, tex_uv.y * 16, tex_id, 0)).rgb;
            } else {
                color += sample_sky(sun_ray, ray_chunk_intersection.nrm);
            }
#elif VISUALIZE_STEP_COMPLEXITY
            // color.r += float(ray_chunk_intersection.steps) * 10.0 / MAX_STEPS;
            color.r += log(float(ray_chunk_intersection.steps) * 1 / MAX_STEPS + 1) * 10;
#elif 0
            if (ray_chunk_intersection.hit) {
                float3 mask = abs(ray_chunk_intersection.nrm);
                float3 intersection_pos = ray_chunk_intersection.pos;
                float3 v_pos = intersection_pos - ray_chunk_intersection.nrm * 0.01;
                float3 b_pos = floor(v_pos + ray_chunk_intersection.nrm * 0.1);
                float3 d1 = mask.zxy;
                float3 d2 = mask.yzx;
                int temp_chunk_index;
                float4 side = float4(
                    load_block_id(globals, b_pos + d1) != BlockID::Air,
                    load_block_id(globals, b_pos + d2) != BlockID::Air,
                    load_block_id(globals, b_pos - d1) != BlockID::Air,
                    load_block_id(globals, b_pos - d2) != BlockID::Air);
                float4 corner = float4(
                    load_block_id(globals, b_pos + d1 + d2) != BlockID::Air,
                    load_block_id(globals, b_pos - d1 + d2) != BlockID::Air,
                    load_block_id(globals, b_pos - d1 - d2) != BlockID::Air,
                    load_block_id(globals, b_pos + d1 - d2) != BlockID::Air);
                float2 ao_uv = fmod(float2(dot(mask * v_pos.yzx, float3(1, 1, 1)), dot(mask * v_pos.zxy, float3(1, 1, 1))), float2(1, 1));
                float4 ao = voxel_ao(side, corner);
                float interp_ao = lerp(lerp(ao.z, ao.w, ao_uv.x), lerp(ao.y, ao.x, ao_uv.x), ao_uv.y);
                color.rgb = 0.5 + interp_ao * 0.5;
            }
#else
            float3 intersection_pos = ray_chunk_intersection.pos;
            BlockID block_id = load_block_id(globals, intersection_pos);

            float3 water_color = 1;

            depth = ray_chunk_intersection.dist;
            total_trace_dist = ray_chunk_intersection.dist;

            int3 intersection_block_pos = int3(intersection_pos);

            float weather = 0; // sin(globals[0].time) * 0.5 + 0.5;

            if (ray_chunk_intersection.hit) {
#if ENABLE_SHADOWS
                sun_ray.o = intersection_pos + ray_chunk_intersection.nrm * 0.002;
                RayIntersection sun_ray_chunk_intersection = trace_chunks(globals, sun_ray);
                float val = float(!sun_ray_chunk_intersection.hit);
                val = max(val * dot(ray_chunk_intersection.nrm, sun_ray.nrm), 0.0);
                float3 light = val * (1 - weather) * sun_col;
#else
                float3 light = float3(0, 0, 0);
#endif

#if ENABLE_FAKE_SKY_LIGHTING
                float3 mask = abs(ray_chunk_intersection.nrm);
                float3 intersection_pos = ray_chunk_intersection.pos;
                float3 v_pos = intersection_pos - ray_chunk_intersection.nrm * 0.01;
                float3 b_pos = floor(v_pos + ray_chunk_intersection.nrm * 0.1);
                float3 d1 = mask.zxy;
                float3 d2 = mask.yzx;
                int temp_chunk_index;
                float4 side = float4(
                    !is_transparent(load_block_id(globals, b_pos + d1)),
                    !is_transparent(load_block_id(globals, b_pos + d2)),
                    !is_transparent(load_block_id(globals, b_pos - d1)),
                    !is_transparent(load_block_id(globals, b_pos - d2)));
                float4 corner = float4(
                    !is_transparent(load_block_id(globals, b_pos + d1 + d2)),
                    !is_transparent(load_block_id(globals, b_pos - d1 + d2)),
                    !is_transparent(load_block_id(globals, b_pos - d1 - d2)),
                    !is_transparent(load_block_id(globals, b_pos + d1 - d2)));
                float2 ao_uv = fmod(float2(dot(mask * v_pos.yzx, float3(1, 1, 1)), dot(mask * v_pos.zxy, float3(1, 1, 1))), float2(1, 1));
                float4 ao = voxel_ao(side, corner);
                float interp_ao = clamp(lerp(lerp(ao.z, ao.w, ao_uv.x), lerp(ao.y, ao.x, ao_uv.x), ao_uv.y), 0, 1);
                // interp_ao = pow(interp_ao, 0.25);
                light += sample_sky(sun_ray, ray_chunk_intersection.nrm) * 0.5 * (interp_ao * 0.9 + 0.1);
#elif !ENABLE_SHADOWS
                light = 1;
#endif

                float3 b_uv = float3(int3(intersection_pos) % 64) / 64;
                BlockFace face_id;
                float2 tex_uv = float2(0, 0);
                uint tex_id;

                get_texture_info(globals, ray_chunk_intersection, intersection_pos, block_id, tex_uv, face_id, tex_id);

                if (tex_id == 8 || tex_id == 11) {
                    float r = rand(int3(intersection_pos));
                    switch (int(r * 4) % 4) {
                    case 0:
                        tex_uv = 1 - tex_uv;
                    case 1:
                        tex_uv = float2(tex_uv.y, tex_uv.x);
                        break;
                    case 2:
                        tex_uv = 1 - tex_uv;
                    case 3:
                        tex_uv = float2(tex_uv.x, tex_uv.y);
                        break;
                    default:
                        break;
                    }
                }

                total_trace_dist = clamp(total_trace_dist, 0, 100);

#if ALBEDO == ALBEDO_TEXTURE
                float3 albedo = ray_chunk_intersection.col;
                // make lava glow
                if (tex_id >= 13 && tex_id <= 20)
                    albedo *= 2;
                // make molten rock glow
                if (tex_id == 24)
                    albedo = albedo * (clamp(1 - pow(length(float3(1, 0, 0) - albedo), 5) * 1.5, 0, 1) * 5 + 1);
                if (tex_id == 11 || tex_id == 10 || tex_id == 21) {
                    float v = biome_noise(intersection_block_pos * GEN_SCL + BLOCK_OFFSET);
                    float3 sand_col = daxa::getTexture2DArray<float4>(globals[0].texture_index).Load(int4(tex_uv.x * 16, tex_uv.y * 16, 27, 0)).rgb;
                    v = clamp((v - 0.0) * 0.1, 0, 1);
                    albedo = lerp(albedo, sand_col, clamp((v * (albedo.g - albedo.r) * 100 > (sand_col.r + sand_col.g + sand_col.b) * 0.33 + 0.7) * v * 5, 0, 1));
                }
#elif ALBEDO == ALBEDO_DEBUG_POS
                float3 albedo = b_uv;
#elif ALBEDO == ALBEDO_DEBUG_NRM
                float3 albedo = ray_chunk_intersection.nrm * 0.5 + 0.5;
#elif ALBEDO == ALBEDO_DEBUG_DIST
                float d = total_trace_dist;
                float3 albedo = d * 0.001;
#elif ALBEDO == ALBEDO_DEBUG_RANDOM
                float3 albedo = float3(rand(int3(intersection_pos)), rand(int3(intersection_pos + 10)), rand(int3(intersection_pos + 20)));
                // float3 albedo = float3(0.5, 0.5, 0.5);
#elif ALBEDO == ALBEDO_DEBUG_BLOCKID
                float3 albedo = (float)block_id * 0.01;
#endif
#if SHOW_PICK_POS
                if (length(intersection_block_pos - view_intersection_block_pos) <= 0.5 + BLOCKEDIT_RADIUS) {
                    float luminance = (albedo.r * 0.2126 + albedo.g * 0.7152 + albedo.b * 0.0722);
                    const float block_outline = 1.0 / 16;
                    albedo = float3(0.2, 0.5, 0.9) * 0.2 + luminance;
                    if (tex_uv.x < block_outline || tex_uv.x > 1 - block_outline || tex_uv.y < block_outline || tex_uv.y > 1 - block_outline)
                        albedo = float3(0.1, 0.4, 1.0) * 0.2 + luminance * 2;
                }
#endif
                color += albedo * light;
                float dist_exp = 1 - exp(pow(ray_chunk_intersection.dist * lerp(0.001, 0.03, weather), 2) * -0.01);
                dist_exp = clamp(dist_exp, 0, 1);
                color = lerp(color, sample_sky(sun_ray, ray_chunk_intersection.nrm), dist_exp);
            } else {
                color += sample_sky(sun_ray, ray_chunk_intersection.nrm);
            }
#endif
            color *= tint;
        }
    }

    color *= inv_subsamples.x * inv_subsamples.y;

    float3 fake_cam_pos = float3(100, 40, 120);

    // {
    //     RayIntersection temp_inter = ray_sphere_intersect(cam_ray, fake_cam_pos, 0.5);
    //     draw(color, depth, float3(1, 0, 1) * (dot(temp_inter.nrm, sun_ray.nrm) * 0.5 + 0.5), temp_inter.dist, temp_inter.hit);
    // }
    // {
    //     float3 rot = float3(-1, 1, 0);
    //     float sin_rot_x = sin(rot.x), cos_rot_x = cos(rot.x);
    //     float sin_rot_y = sin(rot.y), cos_rot_y = cos(rot.y);
    //     // clang-format off
    //     float4x4 view_mat = float4x4(
    //          1,          0,          0, 0,
    //          0,  cos_rot_y,  sin_rot_y, 0,
    //          0, -sin_rot_y,  cos_rot_y, 0,
    //          0,          0,          0, 0
    //     );
    //     float4x4 roty_mat = float4x4(
    //          cos_rot_x,  0, -sin_rot_x, 0,
    //          0,          1,          0, 0,
    //          sin_rot_x,  0,  cos_rot_x, 0,
    //          0,          0,          0, 0
    //     );
    //     // clang-format on

    //     view_mat = mul(roty_mat, view_mat);
    //     front = mul(view_mat, float4(0, 0, 1, 0)).xyz;
    //     right = mul(view_mat, float4(1, 0, 0, 0)).xyz;
    //     up = mul(view_mat, float4(0, 1, 0, 0)).xyz;
    //     float ray_fac = sin(globals[0].time * 5) * 0.5 + 0.5;
    //     float3 ray_dirs[3];
    //     for (uint yi = 1; yi < 10; ++yi) {
    //         for (uint xi = 1; xi < 10; ++xi) {
    //             float2 uv = float2(xi, yi) * 0.1 * 2 - 1;
    //             float2 view_uv = uv * 1.2;
    //             {
    //                 float r0 = atan2(view_uv.y, view_uv.x);
    //                 float r1 = length(view_uv);
    //                 if (r1 > 3.14159f)
    //                     continue;
    //                 float3 r = float3(0, sin(r1), cos(r1));
    //                 r = float3(cos(r0) * r.y, sin(r0) * r.y, r.z);
    //                 ray_dirs[1] = front + right * r.x/r.z + up * r.y/r.z;
    //             }
    //             {
    //                 float r0 = -view_uv.x;
    //                 float r1 = view_uv.y;
    //                 float cos_r0 = cos(r0), sin_r0 = sin(r0);
    //                 float cos_r1 = cos(r1), sin_r1 = sin(r1);
    //                 if (abs(r1) > 3.14159f * 0.5)
    //                     continue;
    //                 if (abs(r0) > 3.14159f)
    //                     continue;
    //                 float3x3 ry = float3x3(
    //                     +cos_r0, 0, -sin_r0,
    //                     0, 1, 0,
    //                     +cos_r0, 0, +cos_r0);
    //                 float3x3 rx = float3x3(
    //                     1, 0, 0,
    //                     0, +cos_r1, +sin_r1,
    //                     0, -sin_r1, +cos_r1);
    //                 float3 r = mul(ry, mul(rx, float3(0, 0, 1)));
    //                 ray_dirs[2] = front + right * r.x/r.z + up * r.y/r.z;
    //             }
    //             {
    //                 ray_dirs[0] = (front + right * view_uv.x + up * view_uv.y);
    //             }
    //             // lines
    //             // RayIntersection temp_inter = ray_capsule_intersect(cam_ray, fake_cam_pos, fake_cam_pos + ray_dir * 10, 0.1);
    //             // points
    //             float3 ray_dir = ray_dirs[0] * ray_fac + ray_dirs[2] * (1 - ray_fac);
    //             RayIntersection temp_inter = ray_sphere_intersect(cam_ray, fake_cam_pos + ray_dir * 10, 1);
    //             draw(color, depth, float3(1, 0, 1) * (dot(temp_inter.nrm, sun_ray.nrm) * 0.5 + 0.5), temp_inter.dist, temp_inter.hit);
    //         }
    //     }
    // }
}
