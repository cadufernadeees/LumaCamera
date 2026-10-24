import SwiftUI
import AVFoundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import Photos
import PhotosUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

private let accent = Color(red: 0.96, green: 0.08, blue: 0.16)

@main struct LumaCameraApp: App {
    var body: some Scene { WindowGroup { CameraScreen().preferredColorScheme(.dark).tint(accent) } }
}

enum ShootMode: String, CaseIterable, Identifiable {
    case photo = "FOTO", portrait = "RETRATO", night = "NOITE", video = "VÍDEO", cinema = "CINEMA"
    var id: String { rawValue }
}
enum Lens: String, CaseIterable, Identifiable {
    case ultra = "0,5×", one = "1×", two = "2×", three = "3×"
    var id: String { rawValue }
    var factor: CGFloat { switch self { case .ultra: 0.5; case .one: 1; case .two: 2; case .three: 3 } }
}

@MainActor final class CameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate {
    @Published var granted = false
    @Published var running = false
    @Published var busy = false
    @Published var mode: ShootMode = .photo
    @Published var lens: Lens = .one
    @Published var zoom: CGFloat = 1
    @Published var exposure: Float = 0
    @Published var flash = false
    @Published var enhance = true
    @Published var simulatedRaw = false
    @Published var mirrorFront = true
    @Published var recording = false
    @Published var showGallery = false
    @Published var showSettings = false
    @Published var video4K = true
    @Published var latest: UIImage?
    @Published var note: String?
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "luma.session")
    private let ci = CIContext()
    private let output = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var device: AVCaptureDevice?
    private var position: AVCaptureDevice.Position = .back

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                Task { @MainActor in
                    guard let self else { return }
                    self.granted = allowed
                    if allowed { self.configure() } else { self.note = "Permita acesso à câmera em Ajustes." }
                }
            }
        default: note = "Permita acesso à câmera em Ajustes."
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: configureMicrophone()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                if allowed { self?.configureMicrophone() }
            }
        default: break
        }
    }

    private func configure() {
        guard !session.isRunning else { return }
        granted = true
        queue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: camera), self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.note = "Não foi possível iniciar a câmera." }
                return
            }
            self.device = camera
            self.session.addInput(input)
            if self.session.canAddOutput(self.output) { self.session.addOutput(self.output) }
            if self.session.canAddOutput(self.movieOutput) { self.session.addOutput(self.movieOutput) }
            self.output.maxPhotoQualityPrioritization = .quality
            self.session.commitConfiguration()
            self.session.startRunning()
            DispatchQueue.main.async { self.running = true }
        }
    }

    private func configureMicrophone() {
        queue.async { [weak self] in
            guard let self, !self.session.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true }),
                  let mic = AVCaptureDevice.default(for: .audio),
                  let input = try? AVCaptureDeviceInput(device: mic), self.session.canAddInput(input) else { return }
            self.session.beginConfiguration()
            self.session.addInput(input)
            self.session.commitConfiguration()
        }
    }

    func setZoom(_ value: CGFloat) {
        zoom = value
        if value < 1 { changeCamera(.back, ultra: true); return }
        queue.async { [weak self] in
            guard let device = self?.device else { return }
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = min(max(value, 1), device.activeFormat.videoMaxZoomFactor)
                device.unlockForConfiguration()
            } catch { }
        }
    }

    func changeCamera(_ requested: AVCaptureDevice.Position? = nil, ultra: Bool = false) {
        let next = requested ?? (position == .back ? .front : .back)
        queue.async { [weak self] in
            guard let self else { return }
            let kind: AVCaptureDevice.DeviceType = ultra ? .builtInUltraWideCamera : .builtInWideAngleCamera
            guard let camera = AVCaptureDevice.default(kind, for: .video, position: next),
                  let input = try? AVCaptureDeviceInput(device: camera) else {
                DispatchQueue.main.async { self.note = "Lente indisponível neste iPhone." }
                return
            }
            self.session.beginConfiguration()
            if let old = self.session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first { self.session.removeInput(old) }
            guard self.session.canAddInput(input) else { self.session.commitConfiguration(); return }
            self.session.addInput(input); self.device = camera; self.position = next
            self.session.commitConfiguration()
            if let connection = self.movieOutput.connection(with: .video), connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .auto
            }
            DispatchQueue.main.async { self.lens = ultra ? .ultra : .one; self.zoom = ultra ? 0.5 : 1 }
        }
    }

    func focus(_ p: CGPoint) {
        queue.async { [weak self] in
            guard let device = self?.device, device.isFocusPointOfInterestSupported else { return }
            do {
                try device.lockForConfiguration()
                device.focusPointOfInterest = p
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = p
                    if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                }
                device.unlockForConfiguration()
            } catch { }
        }
    }

    func setEV(_ ev: Float) {
        exposure = ev
        queue.async { [weak self] in
            guard let device = self?.device else { return }
            do {
                try device.lockForConfiguration()
                let bias = min(max(ev, device.minExposureTargetBias), device.maxExposureTargetBias)
                device.setExposureTargetBias(bias, completionHandler: nil)
                device.unlockForConfiguration()
            } catch { }
        }
    }

    func capture() {
        guard running, !busy else { return }
        guard mode != .video && mode != .cinema else { toggleRecording(); return }
        busy = true; note = nil
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality
        if flash && output.supportedFlashModes.contains(.on) { settings.flashMode = .on }
        output.capturePhoto(with: settings, delegate: self)
    }

    func toggleRecording() {
        guard running else { return }
        if movieOutput.isRecording { movieOutput.stopRecording(); return }
        queue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = self.video4K && self.session.canSetSessionPreset(.hd4K3840x2160) ? .hd4K3840x2160 : .hd1920x1080
            self.session.commitConfiguration()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Luma-\(UUID().uuidString).mov")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
            DispatchQueue.main.async { self.recording = true; self.note = self.mode == .cinema ? "Cinema: vídeo estabilizado; desfoque de fundo depende da câmera." : nil }
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        guard error == nil else {
            Task { @MainActor in self.recording = false; self.note = "Falha ao gravar vídeo. Verifique a permissão do microfone." }
            return
        }
        PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: outputFileURL, options: nil)
        } completionHandler: { [weak self] ok, _ in
            try? FileManager.default.removeItem(at: outputFileURL)
            Task { @MainActor in self?.recording = false; self?.note = ok ? "Vídeo salvo em Fotos." : "Permita salvar na biblioteca Fotos." }
        }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
            Task { @MainActor in self.busy = false; self.note = "Falha na captura. Tente novamente." }; return
        }
        Task { @MainActor in
            let final = await self.process(image)
            self.latest = final
            self.save(final)
        }
    }

    private func process(_ image: UIImage) async -> UIImage {
        guard let input = CIImage(image: image) else { return image }
        var result = input
        if position == .front && mirrorFront {
            result = result.transformed(by: CGAffineTransform(translationX: result.extent.width, y: 0).scaledBy(x: -1, y: 1))
        }
        let color = CIFilter.colorControls()
        color.inputImage = result; color.saturation = 1.06
        color.contrast = enhance ? 1.04 : 1
        color.brightness = enhance ? 0.005 : 0
        result = color.outputImage ?? result
        if enhance {
            let sharp = CIFilter.sharpenLuminance()
            sharp.inputImage = result; sharp.sharpness = 0.28
            result = sharp.outputImage ?? result
        }
        if mode == .night {
            let nr = CIFilter.noiseReduction()
            nr.inputImage = result; nr.noiseLevel = 0.025; nr.sharpness = 0.35
            result = nr.outputImage ?? result
            let shadows = CIFilter.highlightShadowAdjust()
            shadows.inputImage = result; shadows.shadowAmount = 0.28
            result = shadows.outputImage ?? result
        }
        if mode == .portrait {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            let handler = VNImageRequestHandler(ciImage: input, orientation: .up)
            if (try? handler.perform([request])) != nil, let px = request.results?.first?.pixelBuffer {
                let mask = CIImage(cvPixelBuffer: px)
                let scaled = mask.transformed(by: CGAffineTransform(
                    scaleX: input.extent.width / CGFloat(CVPixelBufferGetWidth(px)),
                    y: input.extent.height / CGFloat(CVPixelBufferGetHeight(px))))
                let blur = CIFilter.gaussianBlur()
                blur.inputImage = input; blur.radius = 13
                let blend = CIFilter.blendWithMask()
                blend.inputImage = result; blend.backgroundImage = blur.outputImage?.cropped(to: input.extent); blend.maskImage = scaled
                result = blend.outputImage ?? result
            }
        }
        guard let cg = ci.createCGImage(result, from: result.extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }

    private func save(_ image: UIImage) {
        let data: Data?
        let label: String
        if simulatedRaw, let cg = image.cgImage {
            let buffer = NSMutableData()
            if let destination = CGImageDestinationCreateWithData(buffer, UTType.tiff.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, cg, [kCGImagePropertyTIFFSoftware as String: "Luma Camera - RAW simulado"] as CFDictionary)
                data = CGImageDestinationFinalize(destination) ? buffer as Data : nil
                label = "TIFF processado salvo em Fotos (não é RAW do sensor)."
            } else { data = image.jpegData(compressionQuality: 0.96); label = "Foto salva em Fotos." }
        } else { data = image.jpegData(compressionQuality: 0.96); label = "Foto salva em Fotos." }
        guard let data else { busy = false; note = "Erro ao preparar a imagem."; return }
        PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        } completionHandler: { [weak self] ok, _ in
            DispatchQueue.main.async {
                self?.busy = false
                self?.note = ok ? label : "Confira a permissão de Fotos."
            }
        }
    }

    func importPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task { if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { latest = image } }
    }

    func setResolution4K(_ value: Bool) { video4K = value }
}

struct CameraScreen: View {
    @StateObject private var camera = CameraModel()
    @State private var pinchBase: CGFloat = 1
    @State private var focusPosition: CGPoint?
    @State private var viewer = false
    @State private var picked: PhotosPickerItem?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if camera.granted { CameraPreview(session: camera.session).ignoresSafeArea() }
                LinearGradient(colors: [.black.opacity(0.74), .clear, .clear, .black.opacity(0.86)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                VStack(spacing: 0) {
                    header.padding(.horizontal, 22).padding(.top, 8)
                    Spacer()
                    if let focusPosition {
                        RoundedRectangle(cornerRadius: 4).stroke(accent, lineWidth: 1.5).frame(width: 60, height: 60).position(focusPosition)
                    }
                    Spacer()
                    zoomRow.padding(.bottom, 22)
                    shutterRow.padding(.horizontal, 28)
                    modes.padding(.top, 20)
                    controls.padding(.top, 15)
                    if let note = camera.note { Text(note).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85)).padding(.top, 8) }
                }.padding(.bottom, 8)
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                focusPosition = value.location
                camera.focus(CGPoint(x: value.location.x / geo.size.width, y: value.location.y / geo.size.height))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { focusPosition = nil }
            })
            .simultaneousGesture(MagnificationGesture().onChanged { amount in
                camera.setZoom(min(max(pinchBase * amount, 0.5), 3))
            }.onEnded { amount in
                pinchBase = min(max(pinchBase * amount, 0.5), 3)
                if pinchBase < 1 { camera.changeCamera(.back, ultra: true) }
                else if camera.lens == .ultra { camera.changeCamera(.back) }
            })
            .onAppear { camera.start() }
            .onChange(of: picked) { _, item in camera.importPhoto(item) }
            .sheet(isPresented: $viewer) { GalleryScreen(latest: camera.latest).presentationDetents([.large]) }
            .sheet(isPresented: $camera.showSettings) { settingsSheet.presentationDetents([.medium, .large]) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            LumaMark().frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("LUMA").font(.system(size: 16, weight: .black, design: .rounded)).tracking(3)
                Text("CAMERA PRO").font(.system(size: 9, weight: .bold)).tracking(2).foregroundStyle(accent)
            }
            Spacer()
            Button { camera.showSettings = true } label: {
                Image(systemName: "slider.horizontal.3").foregroundStyle(.white).frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
            }
            Button { camera.flash.toggle() } label: {
                Image(systemName: camera.flash ? "bolt.fill" : "bolt.slash").foregroundStyle(camera.flash ? accent : .white)
                    .frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
            }
            Button { camera.simulatedRaw.toggle() } label: {
                Text(camera.simulatedRaw ? "RAW*" : "HEIF").font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(camera.simulatedRaw ? accent : .white).padding(.horizontal, 11).frame(height: 36)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }.foregroundStyle(.white)
    }

    private var zoomRow: some View {
        HStack(spacing: 8) {
            ForEach(Lens.allCases) { lens in
                Button {
                    camera.lens = lens
                    camera.setZoom(lens.factor)
                    if lens == .ultra { camera.changeCamera(.back, ultra: true) }
                    else if lens == .one && camera.lens == .ultra { camera.changeCamera(.back) }
                } label: {
                    Text(lens.rawValue).font(.system(size: 12, weight: .bold))
                        .foregroundStyle(camera.lens == lens ? .black : .white)
                        .frame(width: 44, height: 36).background(camera.lens == lens ? accent : .black.opacity(0.5), in: Capsule())
                }
            }
            Text(String(format: "%.1f×", Double(camera.zoom))).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.8))
        }
    }

    private var shutterRow: some View {
        HStack {
            Button { viewer = true } label: {
                Group {
                    if let image = camera.latest { Image(uiImage: image).resizable().scaledToFill() }
                    else { Image(systemName: "square.grid.3x3.fill").font(.system(size: 20)) }
                }.frame(width: 52, height: 52).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.7)))
            }
            Spacer()
            Button { camera.capture() } label: {
                Circle().fill(camera.recording ? accent : .white).frame(width: 76, height: 76)
                    .overlay(Circle().stroke(.white, lineWidth: 3).padding(5))
                    .overlay { if camera.busy { ProgressView().tint(accent) } else if camera.recording { RoundedRectangle(cornerRadius: 5).fill(.white).frame(width: 22, height: 22) } }
            }.disabled(!camera.running || camera.busy)
            Spacer()
            Button { camera.enhance.toggle() } label: {
                Image(systemName: camera.enhance ? "sparkles" : "sparkle").font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(camera.enhance ? accent : .white).frame(width: 52, height: 52).background(.ultraThinMaterial, in: Circle())
            }
        }
    }

    private var modes: some View {
        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 22) {
            ForEach(ShootMode.allCases) { mode in
                Button { camera.mode = mode } label: {
                    Text(mode.rawValue).font(.system(size: 11, weight: .bold)).tracking(1)
                        .foregroundStyle(camera.mode == mode ? accent : .white.opacity(0.75))
                        .padding(.bottom, 5).overlay(alignment: .bottom) { if camera.mode == mode { Capsule().fill(accent).frame(height: 2) } }
                }
            }
        }.padding(.horizontal, 22) }.frame(maxWidth: .infinity)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Text("EV").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(accent)
            Slider(value: Binding(get: { Double(camera.exposure) }, set: { camera.setEV(Float($0)) }), in: -2...2).tint(accent).frame(maxWidth: 140)
            Text(String(format: "%+.1f", camera.exposure)).font(.system(size: 10, design: .monospaced)).frame(width: 32)
            Button { camera.changeCamera() } label: { Image(systemName: "arrow.triangle.2.circlepath.camera").frame(width: 42, height: 36).background(.ultraThinMaterial, in: Capsule()) }
        }.foregroundStyle(.white).padding(.horizontal, 18)
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Imagem") {
                    Toggle("Aprimoramento inteligente", isOn: $camera.enhance)
                    Toggle("RAW simulado (TIFF processado)", isOn: $camera.simulatedRaw)
                    Toggle("Espelhar selfie frontal", isOn: $camera.mirrorFront)
                }
                Section("Vídeo") {
                    Toggle("Gravar em 4K", isOn: $camera.video4K)
                    Text("Cinema usa estabilização e gravação nativa do iPhone. O iPhone 14 não oferece o desfoque de profundidade Cinema do Pro em vídeo para processamento por este app.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Sobre") {
                    Label("Luma Camera Pro", systemImage: "camera.aperture").foregroundStyle(accent)
                    Text("Zoom digital não cria detalhes ópticos. RAW simulado é uma imagem TIFF processada, não dados RAW do sensor.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Ajustes da câmera")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { camera.showSettings = false }.tint(accent) } }
        }.preferredColorScheme(.dark)
    }
}

private struct LumaMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [Color(red: 1, green: 0.22, blue: 0.28), accent], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "camera.aperture").font(.system(size: 23, weight: .bold)).foregroundStyle(.white)
            Circle().fill(.white).frame(width: 4, height: 4)
        }.shadow(color: accent.opacity(0.42), radius: 8, y: 2)
    }
}

private struct GalleryScreen: View {
    let latest: UIImage?
    @State private var assets: [PHAsset] = []
    @State private var selected: UIImage?
    @State private var accessMessage: String?
    private let manager = PHImageManager.default()
    private let columns = [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    if let latest { Button { selected = latest } label: { Image(uiImage: latest).resizable().scaledToFill().frame(height: 125).clipped() } }
                    ForEach(assets, id: \.localIdentifier) { asset in
                        Button { load(asset, size: CGSize(width: 1000, height: 1000), detail: true) } label: {
                            AssetThumbnail(asset: asset, manager: manager).frame(height: 125).clipped()
                        }
                    }
                }.padding(2)
                if let accessMessage { Text(accessMessage).font(.footnote).foregroundStyle(.secondary).padding() }
            }
            .background(.black)
            .navigationTitle("Fotos e vídeos")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fechar") { dismiss() }.tint(accent) } }
            .task { loadAssets() }
            .fullScreenCover(item: Binding(get: { selected.map(PreviewImage.init) }, set: { selected = $0?.image })) { item in
                ZStack { Color.black.ignoresSafeArea(); Image(uiImage: item.image).resizable().scaledToFit() }
                    .onTapGesture { selected = nil }
            }
        }.preferredColorScheme(.dark)
    }
    @Environment(\.dismiss) private var dismiss

    private func loadAssets() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                guard status == .authorized || status == .limited else { accessMessage = "Permita acesso a Fotos para mostrar sua galeria."; return }
                let options = PHFetchOptions(); options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                let result = PHAsset.fetchAssets(with: options)
                assets = (0..<result.count).map { result.object(at: $0) }
            }
        }
    }
    private func load(_ asset: PHAsset, size: CGSize, detail: Bool) {
        manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: nil) { image, _ in if let image { selected = image } }
    }
}

private struct PreviewImage: Identifiable { let id = UUID(); let image: UIImage; init(_ image: UIImage) { self.image = image } }
private struct AssetThumbnail: View {
    let asset: PHAsset; let manager: PHImageManager
    @State private var image: UIImage?
    var body: some View {
        Group { if let image { Image(uiImage: image).resizable().scaledToFill() } else { Rectangle().fill(.white.opacity(0.08)) } }
            .task { manager.requestImage(for: asset, targetSize: CGSize(width: 300, height: 300), contentMode: .aspectFill, options: nil) { result, _ in image = result } }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session; view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ view: PreviewView, context: Context) { view.previewLayer.session = session }
}
private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

