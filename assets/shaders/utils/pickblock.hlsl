#include "world/common.hlsl"
#include "utils/intersect.hlsl"
#include "player.hlsl"

[numthreads(1, 1, 1)] void main() {
    StructuredBuffer<Globals> globals = daxa::getBuffer<Globals>(p.globals_sb);
    StructuredBuffer<PlayerBuffer> player_buffer = daxa::getBuffer<PlayerBuffer>(p.player_buf_id);

    player_buffer[0].player.update(globals, player_buffer[0].input);
    Ray ray;

    float3 front = mul(player_buffer[0].player.camera.view_mat, float4(0, 0, 1, 0)).xyz;
    ray.o = player_buffer[0].player.pos.xyz;
    ray.nrm = normalize(front);
    ray.inv_nrm = 1 / ray.nrm;
    RayIntersection view_chunk_intersection = trace_chunks(globals, ray);
    float3 view_intersection_pos0 = view_chunk_intersection.pos + view_chunk_intersection.nrm * -0.01;
    float3 view_intersection_pos1 = view_chunk_intersection.pos + view_chunk_intersection.nrm * +0.01;
    if (view_chunk_intersection.hit) {
        globals[0].pick_pos[0] = float4(view_intersection_pos0, 0);
        globals[0].pick_pos[1] = float4(view_intersection_pos1, 0);
    } else {
        globals[0].pick_pos[0] = float4(-100000, -100000, -100000, 0);
        globals[0].pick_pos[1] = globals[0].pick_pos[0];
    }
}
