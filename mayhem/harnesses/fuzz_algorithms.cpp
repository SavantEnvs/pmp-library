// libFuzzer harness for pmp's mesh-processing algorithms. The mesh is built straight from the
// fuzz bytes through the public SurfaceMesh API (add_vertex / add_triangle), NOT through a file
// reader: parsing is covered by the fuzz_read_* targets, and here every input reaches the
// algorithms instead of dying in read_off.
//
// Input layout (little-endian, missing bytes read as 0):
//   u8  op              algorithm selector (op % 8)
//   u16 nv              vertex count = 3 + nv % 2046
//   nv x 3 x i16        vertex coordinates, each scaled by 1/1024 (always finite)
//   rest: 3 x u16 ...   triangles; each index is taken % vertex count
// A triangle that repeats a vertex is not a face and is not added. add_triangle throws
// TopologyException on non-manifold input; such a triangle is skipped and the rest are added.
// A fresh mesh per input; no files, no global state.
#include <cstdint>
#include <cstring>
#include <vector>

#include "pmp/surface_mesh.h"
#include "pmp/algorithms/curvature.h"
#include "pmp/algorithms/decimation.h"
#include "pmp/algorithms/features.h"
#include "pmp/algorithms/hole_filling.h"
#include "pmp/algorithms/normals.h"
#include "pmp/algorithms/remeshing.h"
#include "pmp/algorithms/smoothing.h"
#include "pmp/algorithms/subdivision.h"
#include "pmp/algorithms/utilities.h"

namespace {
struct Reader
{
    const uint8_t* d;
    size_t n, pos = 0;
    uint8_t u8() { return pos < n ? d[pos++] : 0; }
    uint16_t u16()
    {
        uint16_t lo = u8();
        return (uint16_t)(lo | (uint16_t(u8()) << 8));
    }
    bool more() const { return pos < n; }
};
} // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
    Reader r{data, size};
    const uint8_t op = r.u8();
    const size_t nv = 3 + r.u16() % 2046;

    try
    {
        pmp::SurfaceMesh mesh;
        std::vector<pmp::Vertex> v;
        v.reserve(nv);
        for (size_t i = 0; i < nv; ++i)
        {
            float c[3];
            for (float& x : c)
                x = int16_t(r.u16()) / 1024.0f;
            v.push_back(mesh.add_vertex(pmp::Point(c[0], c[1], c[2])));
        }
        // Cost bound, not a crash filter: decimation, remeshing and subdivision are superlinear,
        // so cap the face count to keep one execution fast.
        while (r.more() && mesh.n_faces() < 4000)
        {
            size_t a = r.u16() % nv, b = r.u16() % nv, c = r.u16() % nv;
            if (a == b || b == c || a == c)
                continue;
            try
            {
                mesh.add_triangle(v[a], v[b], v[c]);
            }
            catch (const pmp::TopologyException&)
            {
            }
        }
        if (mesh.n_faces() == 0)
            return 0;

        switch (op % 8)
        {
            case 0:
                pmp::decimate(mesh, mesh.n_vertices() / 2);
                break;
            case 1:
                pmp::loop_subdivision(mesh);
                break;
            case 2:
                pmp::uniform_remeshing(mesh, pmp::mean_edge_length(mesh), 1);
                break;
            case 3:
                for (auto h : mesh.halfedges())
                    if (mesh.is_boundary(h))
                    {
                        pmp::fill_hole(mesh, h);
                        break;
                    }
                break;
            case 4:
                pmp::explicit_smoothing(mesh, 1);
                break;
            case 5:
                pmp::curvature(mesh, pmp::Curvature::Mean, 1);
                break;
            case 6:
                pmp::detect_features(mesh, 45.0);
                pmp::catmull_clark_subdivision(mesh);
                break;
            case 7:
                pmp::vertex_normals(mesh);
                pmp::connected_components(mesh);
                pmp::min_face_area(mesh);
                break;
        }
        mesh.garbage_collection();
    }
    catch (const std::exception&)
    {
        // pmp throws TopologyException / InvalidInputException on meshes an algorithm rejects
    }
    return 0;
}
