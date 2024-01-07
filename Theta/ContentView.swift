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

    private var graphLib: MTLLibrary!
    private var commandQueue: MTLCommandQueue!
    private var pipelineState: MTLRenderPipelineState?

    init() {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        self.delegate = self
        self.enableSetNeedsDisplay = true
        self.autoResizeDrawable = true
        self.contentMode = .topLeft

        guard let device,
              let commandQueue = device.makeCommandQueue() else {
            return
        }
        self.commandQueue = commandQueue

        guard let graphURL = Bundle.main.url(forResource: "Graph", withExtension: "metallib"),
              let graphLib = try? device.makeLibrary(URL: graphURL) else {
            return
        }

        self.graphLib = graphLib
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        self.setNeedsDisplay()
    }

    func getPipelineState() -> MTLRenderPipelineState? {
        if let pipelineState { return pipelineState }

        guard let equation else {
            return nil
        }
        guard let device else {
            print("Failed to get device")
            return nil
        }

        let source = """
            #include <metal_stdlib>
            using namespace metal;

            [[visible]] float eq(float x, float y) {
                return y - (\(equation));
            }
        """

        let sourceCompileOptions = MTLCompileOptions()
        sourceCompileOptions.fastMathEnabled = false
        let library = try! device.makeLibrary(source: source, options: sourceCompileOptions)
        let eq = library.makeFunction(name: "eq")!

        let linkedFunctions = MTLLinkedFunctions()
        linkedFunctions.functions = [eq]

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = graphLib.makeFunction(name: "graphVertex")
        pipelineDescriptor.fragmentFunction = graphLib.makeFunction(name: "graphFragment")
        pipelineDescriptor.fragmentLinkedFunctions = linkedFunctions;
        pipelineDescriptor.colorAttachments[0].pixelFormat = colorPixelFormat

        pipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        return pipelineState!
    }

    func draw(in view: MTKView) {
        guard let pipelineState = getPipelineState() else {
            return
        }

        let device = device!
        let currentRenderPassDescriptor = currentRenderPassDescriptor!
        let currentDrawable = currentDrawable!

        let commandBuffer = commandQueue.makeCommandBuffer()!
        let commandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: currentRenderPassDescriptor)!

        commandEncoder.setRenderPipelineState(pipelineState)

        var offset = (Float(1), Float(1))
        let offsetBuffer = device.makeBuffer(bytes: &offset,
                                           length: MemoryLayout<(Float, Float)>.stride)!
        commandEncoder.setFragmentBuffer(offsetBuffer, offset: 0, index: 1)

        var size = (Float(drawableSize.width), Float(drawableSize.height))
        let sizeBuffer = device.makeBuffer(bytes: &size,
                                           length: MemoryLayout<(Float, Float)>.stride)!
        commandEncoder.setFragmentBuffer(sizeBuffer, offset: 0, index: 2)

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
