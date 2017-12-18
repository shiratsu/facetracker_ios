//
//  ViewController.swift
//  AutoCamera
//
//  Created by Pawel Chmiel on 26.09.2016.
//  Copyright © 2016 Pawel Chmiel. All rights reserved.
//

import UIKit
import AVFoundation

final class ViewController: UIViewController {

    var session: AVCaptureSession?
    var stillOutput = AVCaptureStillImageOutput()
    var borderLayer: CAShapeLayer?
   
    // 顔とかその他情報を表示するためのview
    let detailsView: DetailsView = {
        let detailsView = DetailsView()
        detailsView.setup()
        
        return detailsView
    }()
    
    // カメラの映像を画面に表示する為のレイヤー
    lazy var previewLayer: AVCaptureVideoPreviewLayer? = {
        var previewLay = AVCaptureVideoPreviewLayer(session: self.session!)
        previewLay?.videoGravity = AVLayerVideoGravityResizeAspectFill
        
        return previewLay
    }()
    
    // カメラの定義
    // positionをbackにすると通常モード
    // frontにすると自撮りモード
    lazy var backCamera: AVCaptureDevice? = {
        guard let devices = AVCaptureDevice.devices(withMediaType: AVMediaTypeVideo) as? [AVCaptureDevice] else { return nil }
        
        return devices.filter { $0.position == .front }.first
    }()
    
    
    // 顔認識オブジェクト
    let faceDetector = CIDetector(ofType: CIDetectorTypeFace, context: nil, options: [CIDetectorAccuracy : CIDetectorAccuracyLow])
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.frame
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let previewLayer = previewLayer else { return }
        
        view.layer.addSublayer(previewLayer)
        view.addSubview(detailsView)
        view.bringSubview(toFront: detailsView)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        sessionPrepare()
        session?.startRunning()
    }
}

extension ViewController {

    func sessionPrepare() {
        
        // まずはカメラ使うにはこいつが必要
        session = AVCaptureSession()
       
        // セッションとカメラをセット
        guard let session = session, let captureDevice = backCamera else { return }
        
        // キャプチャの品質レベル、ビットレートなどのクオリティを設定
        session.sessionPreset = AVCaptureSessionPresetPhoto
        
        do {
            // AVCaptureDeviceオブジェクトからデータをキャプチャするために使用するAVCaptureInputのサブクラスです。
            // これを使用して、デバイスをAVCaptureSessionに繋ぎます。
            let deviceInput = try AVCaptureDeviceInput(device: captureDevice)
            session.beginConfiguration()
            
            // セッションにカメラを入力機器として接続
            if session.canAddInput(deviceInput) {
                session.addInput(deviceInput)
            }
            
            // アウトプットの設定
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String : NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)]
            
            // 遅れてきたフレームは無視する
            output.alwaysDiscardsLateVideoFrames = true
        
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
            
            // 設定をコミットする。
            session.commitConfiguration()
            
            // フレームをキャプチャするためのサブスレッド用のシリアルキューを用意
            // didOutputSampleBufferを呼ぶため用
            let queue = DispatchQueue(label: "output.queue")
            output.setSampleBufferDelegate(self, queue: queue)
            
        } catch {
            print("error with creating AVCaptureDeviceInput")
        }
    }
}

extension ViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    
    
    
    /// キャプチャ中にずっと呼ばれる。
    /// 新しいビデオフレームが書かれたら呼ばれる
    ///
    /// - Parameters:
    ///   - captureOutput: <#captureOutput description#>
    ///   - sampleBuffer: <#sampleBuffer description#>
    ///   - connection: <#connection description#>
    func captureOutput(_ captureOutput: AVCaptureOutput!, didOutputSampleBuffer sampleBuffer: CMSampleBuffer!, from connection: AVCaptureConnection!) {
        
        // サンプルバッファからピクセルバッファを取り出す
        // ピクセルバッファをベースにCoreImageのCIImageオブジェクトを作成
        // CIImageからUIImageを作成することができる
        let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        let attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, sampleBuffer, kCMAttachmentMode_ShouldPropagate)
        
        // attachements無くても作れるけど、attachmentsは必要なのかどうかよくわからんなあ
        let ciImage = CIImage(cvImageBuffer: pixelBuffer!, options: attachments as! [String : Any]?)
        let options: [String : Any] = [CIDetectorImageOrientation: exifOrientation(orientation: UIDevice.current.orientation),
                                       CIDetectorSmile: true,
                                       CIDetectorEyeBlink: true]
        
        // facedetectorから顔の特徴を全部取得
        let allFeatures = faceDetector?.features(in: ciImage, options: options)
    
        let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        
        // get the clean aperture
        // the clean aperture is a rectangle that defines the portion of the encoded pixel dimensions
        // that represents image data valid for display.
        let cleanAperture = CMVideoFormatDescriptionGetCleanAperture(formatDescription!, false)
        
        guard let features = allFeatures else { return }
        
        for feature in features {
            if let faceFeature = feature as? CIFaceFeature {
                
                // 顔の形を取得する
                let faceRect = calculateFaceRect(facePosition: faceFeature.mouthPosition, faceBounds: faceFeature.bounds, clearAperture: cleanAperture)
                let featureDetails = ["has smile: \(faceFeature.hasSmile)",
                    "has closed left eye: \(faceFeature.leftEyeClosed)",
                    "has closed right eye: \(faceFeature.rightEyeClosed)"]
                
                update(with: faceRect, text: featureDetails.joined(separator: "\n"))
            }
        }
        
        if features.count == 0 {
            DispatchQueue.main.async {
                self.detailsView.alpha = 0.0
            }
        }
        
    }
    
    func exifOrientation(orientation: UIDeviceOrientation) -> Int {
        switch orientation {
        case .portraitUpsideDown:
            return 8
        case .landscapeLeft:
            return 3
        case .landscapeRight:
            return 1
        default:
            return 6
        }
    }
    
    func videoBox(frameSize: CGSize, apertureSize: CGSize) -> CGRect {
        let apertureRatio = apertureSize.height / apertureSize.width
        let viewRatio = frameSize.width / frameSize.height
        
        var size = CGSize.zero
     
        if (viewRatio > apertureRatio) {
            size.width = frameSize.width
            size.height = apertureSize.width * (frameSize.width / apertureSize.height)
        } else {
            size.width = apertureSize.height * (frameSize.height / apertureSize.width)
            size.height = frameSize.height
        }
        
        var videoBox = CGRect(origin: .zero, size: size)
       
        if (size.width < frameSize.width) {
            videoBox.origin.x = (frameSize.width - size.width) / 2.0
        } else {
            videoBox.origin.x = (size.width - frameSize.width) / 2.0
        }
        
        if (size.height < frameSize.height) {
            videoBox.origin.y = (frameSize.height - size.height) / 2.0
        } else {
            videoBox.origin.y = (size.height - frameSize.height) / 2.0
        }
       
        return videoBox
    }

    
    /// 顔を取得する処理
    ///
    /// - Parameters:
    ///   - facePosition: <#facePosition description#>
    ///   - faceBounds: <#faceBounds description#>
    ///   - clearAperture: <#clearAperture description#>
    /// - Returns: <#return value description#>
    func calculateFaceRect(facePosition: CGPoint, faceBounds: CGRect, clearAperture: CGRect) -> CGRect {
        let parentFrameSize = previewLayer!.frame.size
        
        print("----------------parentFrameSize---------------------")
        print(parentFrameSize)
        
        
        let previewBox = videoBox(frameSize: parentFrameSize, apertureSize: clearAperture.size)
        
        print("----------------previewBox.size---------------------")
        print(previewBox.size)
        
        var faceRect = faceBounds
        
        swap(&faceRect.size.width, &faceRect.size.height)
        swap(&faceRect.origin.x, &faceRect.origin.y)

        let widthScaleBy = previewBox.size.width / clearAperture.size.height
        let heightScaleBy = previewBox.size.height / clearAperture.size.width
        
        faceRect.size.width *= widthScaleBy
        faceRect.size.height *= heightScaleBy
        faceRect.origin.x *= widthScaleBy
        faceRect.origin.y *= heightScaleBy
        
        faceRect = faceRect.offsetBy(dx: 0.0, dy: previewBox.origin.y)
        let frame = CGRect(x: parentFrameSize.width - faceRect.origin.x - faceRect.size.width / 2.0 - previewBox.origin.x / 2.0, y: faceRect.origin.y, width: faceRect.width, height: faceRect.height)
        
        return frame
    }
}

extension ViewController {
    func update(with faceRect: CGRect, text: String) {
        DispatchQueue.main.async {
            UIView.animate(withDuration: 0.2) {
                self.detailsView.detailsLabel.text = text
                self.detailsView.alpha = 1.0
                self.detailsView.frame = faceRect
            }
        }
    }
}
