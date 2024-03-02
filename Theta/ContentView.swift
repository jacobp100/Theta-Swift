//
//  ContentView.swift
//  Theta
//
//  Created by Jacob Parker on 02/01/2024.
//

import SwiftUI
import UIKit
import MetalKit

protocol InfiniteCanvasDelegate: AnyObject {
    var contentOffset: CGPoint { get set }
    var zoomScale: CGFloat { get set }
}

class InfiniteCanvasInteraction: NSObject, UIGestureRecognizerDelegate {
    var minZoom: CGFloat = 0.1
    var maxZoom: CGFloat = 10.0

    var view: UIView!
    weak var delegate: InfiniteCanvasDelegate?

    private var panGestureRecognizer: UIPanGestureRecognizer!
    private var pinchGestureRecognizer: UIPinchGestureRecognizer!

    private class ContentOffsetItem: NSObject, UIDynamicItem {
        weak var parent: InfiniteCanvasInteraction?

        var center: CGPoint {
            get { parent?.delegate?.contentOffset ?? .zero }
            set { parent?.delegate?.contentOffset = newValue }
        }

        // Not used
        var bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        var transform = CGAffineTransform.identity
    }

    private let animator = UIDynamicAnimator()
    private let frictionDelegate = ContentOffsetItem()

    init(for view: UIView) {
        super.init()

        self.view = view

        frictionDelegate.parent = self

        panGestureRecognizer = UIPanGestureRecognizer(target: self,
                                                      action: #selector(didPan))
        panGestureRecognizer.allowedScrollTypesMask = .all
        panGestureRecognizer.delegate = self

        pinchGestureRecognizer = UIPinchGestureRecognizer(target: self,
                                                          action: #selector(didPinch))
        pinchGestureRecognizer.delegate = self
    }

    func addGestureRecognizers() {
        view.addGestureRecognizer(panGestureRecognizer)
        view.addGestureRecognizer(pinchGestureRecognizer)
    }

    func removeGestureRecognizers() {
        view.removeGestureRecognizer(panGestureRecognizer)
        view.removeGestureRecognizer(pinchGestureRecognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
        animator.removeAllBehaviors()
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    @objc private func didPan(_ gesture: UIPanGestureRecognizer) {
        guard let delegate else { return }

        switch gesture.state {
        case .changed:
            let translation = gesture.translation(in: view)
            delegate.contentOffset = CGPoint(x: delegate.contentOffset.x - translation.x / delegate.zoomScale,
                                             y: delegate.contentOffset.y - translation.y / delegate.zoomScale)
            gesture.setTranslation(.zero, in: view)
        case .ended:
            var velocity = gesture.velocity(in: view)
            velocity = CGPoint(x: -velocity.x / delegate.zoomScale,
                               y: -velocity.y / delegate.zoomScale)
            let friction = UIDynamicItemBehavior(items: [frictionDelegate])
            friction.resistance = 2
            friction.addLinearVelocity(velocity, for: frictionDelegate)
            friction.isAnchored = false
            animator.addBehavior(friction)
        case .possible, .began, .cancelled, .failed:
            break
        @unknown default:
            break
        }
    }

    @objc private func didPinch(_ gesture: UIPinchGestureRecognizer) {
        guard let delegate else { return }

        switch gesture.state {
        case .changed:
            let zoomScaleBefore = delegate.zoomScale
            delegate.zoomScale = min(max(delegate.zoomScale * gesture.scale, minZoom), maxZoom)
            let delta = delegate.zoomScale / zoomScaleBefore
            delegate.contentOffset = CGPoint(x: delegate.contentOffset.x / delta,
                                             y: delegate.contentOffset.y / delta)
            gesture.scale = 1
        case .possible, .began, .ended, .cancelled, .failed:
            break
        @unknown default:
            break
        }
    }
}

class GraphView: MTKView, MTKViewDelegate {
    var equation: String? { didSet { if equation != oldValue { resetPipelineState() } } }
    @Invalidating(.display) var contentOffset: CGPoint = .zero
    @Invalidating(.display) var zoomScale: CGFloat = 1

    private var graphLib: MTLLibrary?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?

    init() {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        self.delegate = self
        self.enableSetNeedsDisplay = true
        self.autoResizeDrawable = true

        guard let device, device.supportsFunctionPointers else {
            return
        }

        self.commandQueue = device.makeCommandQueue()

        if let graphURL = Bundle.main.url(forResource: "Graph", withExtension: "metallib"),
           let graphLib = try? device.makeLibrary(URL: graphURL) {
            self.graphLib = graphLib
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        self.setNeedsDisplay()
    }

    func resetPipelineState() {
        self.pipelineState = nil
        setNeedsDisplay()
    }

    func buildPipelineStateIfNeeded() -> MTLRenderPipelineState? {
        if let pipelineState {
            return pipelineState
        }

        guard let equation,
              let device,
              let graphLib else {
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
        guard let library = try? device.makeLibrary(source: source, options: sourceCompileOptions),
              let eq = library.makeFunction(name: "eq") else {
            print("Failed to build library")
            return nil
        }

        let linkedFunctions = MTLLinkedFunctions()
        linkedFunctions.functions = [eq]

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = graphLib.makeFunction(name: "graphVertex")
        pipelineDescriptor.fragmentFunction = graphLib.makeFunction(name: "graphFragment")
        pipelineDescriptor.fragmentLinkedFunctions = linkedFunctions;
        pipelineDescriptor.colorAttachments[0].pixelFormat = colorPixelFormat

        guard let pipelineState = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor) else {
            print("Failed to build pipeline state")
            return nil
        }

        self.pipelineState = pipelineState

        return pipelineState
    }

    func draw(in view: MTKView) {
        guard let device,
              let currentRenderPassDescriptor,
              let currentDrawable,
              let commandQueue,
              let pipelineState = buildPipelineStateIfNeeded(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let commandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: currentRenderPassDescriptor)!

        commandEncoder.setRenderPipelineState(pipelineState)

        let pixelScale = window?.screen.scale ?? 1
        var contentOffset = (
            Float(contentOffset.x * pixelScale - drawableSize.width / 2),
            Float(contentOffset.y * pixelScale - drawableSize.height / 2)
        )
        let contentOffsetBuffer = device.makeBuffer(bytes: &contentOffset,
                                                    length: MemoryLayout<(Float, Float)>.stride)!
        commandEncoder.setFragmentBuffer(contentOffsetBuffer, offset: 0, index: 1)

        var zoomScale = Float(zoomScale * 50)
        let zoomScaleBuffer = device.makeBuffer(bytes: &zoomScale,
                                                length: MemoryLayout<Float>.stride)!
        commandEncoder.setFragmentBuffer(zoomScaleBuffer, offset: 0, index: 2)

        commandEncoder.drawPrimitives(type: .triangle,
                                      vertexStart: 0,
                                      vertexCount: 6)

        commandEncoder.endEncoding()

        commandBuffer.present(currentDrawable)

        commandBuffer.commit()
    }
}

class ScrollableGraphView: GraphView, InfiniteCanvasDelegate {
    private var infiniteCanvasInteraction: InfiniteCanvasInteraction!

    override init() {
        super.init()
        self.infiniteCanvasInteraction = InfiniteCanvasInteraction(for: self)
        self.infiniteCanvasInteraction.delegate = self
        self.infiniteCanvasInteraction.addGestureRecognizers()
    }
    
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct Graph: UIViewRepresentable {
    let equation: String?

    func makeUIView(context: Context) -> ScrollableGraphView {
        let uiView = ScrollableGraphView()
        uiView.equation = equation
        return uiView
    }

    func updateUIView(_ uiView: ScrollableGraphView, context: Context) {
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
