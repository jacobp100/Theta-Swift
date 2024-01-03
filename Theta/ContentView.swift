//
//  ContentView.swift
//  Theta
//
//  Created by Jacob Parker on 02/01/2024.
//

import SwiftUI
import UIKit
import MetalKit

class GraphView: MTKView, MTKViewDelegate {
    var equation: String? {
        didSet {
            if equation != oldValue {
                pipelineState = nil
                setNeedsDisplay()
            }
        }
    }

    private struct ScreenSize {
        let width: Float
        let height: Float
    }

    private var commandQueue: MTLCommandQueue!
    private var pipelineState: MTLRenderPipelineState?

    init() {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        self.delegate = self
        self.enableSetNeedsDisplay = true

        guard let device,
              let commandQueue = device.makeCommandQueue() else {
            return
        }
        self.commandQueue = commandQueue
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        draw(in: view, size: size)
    }

    func draw(in view: MTKView) {
        let scale = UIScreen.main.scale
        let size = CGSize(width: frame.size.width * scale, height: frame.size.height * scale)
        draw(in: view, size: size)
    }

    func getPipelineState() -> MTLRenderPipelineState? {
        if let pipelineState { return pipelineState }

        guard let equation else {
            return nil
        }
        guard let device,
              let currentDrawable,
              let currentRenderPassDescriptor else {
            print("Failed to get device")
            return nil
        }

        let source = """
            #include <metal_stdlib>
            using namespace metal;

            struct ScreenSize {
                float width;
                float height;
            };

            float eq(float x, float y) {
                return y - (\(equation));
            }

            vertex float4 graphVertex(uint vertexID [[vertex_id]]) {
                float3 vertices[6] = {
                    float3(-1.0, -1.0, 0.0),
                    float3(1.0, -1.0, 0.0),
                    float3(-1.0, 1.0, 0.0),
                    float3(1.0, -1.0, 0.0),
                    float3(1.0, 1.0, 0.0),
                    float3(-1.0, 1.0, 0.0),
                };

                float3 position = vertices[vertexID];

                return float4(position, 1.0);
            }

            fragment half4 graphFragment(float4 position [[position]], constant ScreenSize &size [[buffer(1)]]) {
                float scale = 50;
                float thicknessAndMode = 2;
                half4 currentColor = half4(0.0, 0.0, 1.0, 1.0);

                float x = (position.x - size.width * 0.5) / scale;
                float y = (size.height * 0.5 - position.y) / scale;
                float dx = dfdx(x);
                float dy = dfdy(y);
                float z = eq(x, y);

                // Evaluate all 4 adjacent +/- neighbor pixels
                float2 zNeg = float2(eq(x - dx, y), eq(x, y - dy));
                float2 zPos = float2(eq(x + dx, y), eq(x, y + dy));

                // Compute the x and y slopes
                float2 slope = (zPos - zNeg) * 0.5;

                // Compute the gradient (the shortest point on the curve is assumed to lie in this direction)
                float2 gradient = normalize(slope);

                // Use the parabola "a*t^2 + b*t + z = 0" to approximate the function along the gradient
                float a = dot((zNeg + zPos) * 0.5 - z, gradient * gradient);
                float b = dot(slope, gradient);

                // The distance to the curve is the closest solution to the parabolic equation
                float distanceToCurve = 0.0;
                float thickness = abs(thicknessAndMode);

                if (abs(a) < 1.0e-6) {
                    // Linear equation: "b*t + z = 0"
                    distanceToCurve = abs(z / b);
                } else {
                    // Quadratic equation: "a*t^2 + b*t + z = 0"
                    float discriminant = b * b - 4.0 * a * z;
                    if (discriminant < 0.0) {
                        distanceToCurve = thickness;
                    } else {
                        discriminant = sqrt(discriminant);
                        distanceToCurve = min(abs(b + discriminant), abs(b - discriminant)) / abs(2.0 * a);
                    }
                }

                // Antialias the edge using the distance from the curve
                float edgeAlpha = clamp(abs(thickness) - distanceToCurve, 0.0, 1.0);

                return currentColor * edgeAlpha;
            }
        """

        let library = try! device.makeLibrary(source: source, options: nil)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "graphVertex")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "graphFragment")
        pipelineDescriptor.colorAttachments[0].pixelFormat = colorPixelFormat

        pipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        return pipelineState!
    }

    func draw(in view: MTKView, size: CGSize) {
        guard let pipelineState = getPipelineState() else {
            return
        }

        let device = device!
        let currentRenderPassDescriptor = currentRenderPassDescriptor!
        let currentDrawable = currentDrawable!

        let commandBuffer = commandQueue.makeCommandBuffer()!
        let commandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: currentRenderPassDescriptor)!

        commandEncoder.setRenderPipelineState(pipelineState)

        var screenSize = ScreenSize(width: Float(size.width), height: Float(size.height))
        let sizeBuffer = device.makeBuffer(bytes: &screenSize, length: MemoryLayout<ScreenSize>.stride)!
        commandEncoder.setFragmentBuffer(sizeBuffer, offset: 0, index: 1)

        commandEncoder.drawPrimitives(type: .triangle,
                                      vertexStart: 0,
                                      vertexCount: 6)

        commandEncoder.endEncoding()

        commandBuffer.present(currentDrawable)

        commandBuffer.commit()
    }
}

struct Graph: UIViewRepresentable {
    let equation: String?

    func makeUIView(context: Context) -> GraphView {
        let uiView = GraphView()
        uiView.equation = equation
        return uiView
    }

    func updateUIView(_ uiView: GraphView, context: Context) {
        uiView.equation = equation
    }
}

struct ContentView: View {
    @State var editingEquation = "10 * sin(x) / x"
    @State var equation: String?

    func render() {
        equation = editingEquation
    }

    var body: some View {
        VStack {
            TextField("Function", text: $editingEquation)
                .onSubmit(render)

            Graph(equation: equation)
                .onAppear(perform: render)
        }
    }
}

#Preview {
    ContentView()
}
