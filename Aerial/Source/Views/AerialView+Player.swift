//
//  AerialView+Player.swift
//  Aerial
//
//  Created by Guillaume Louel on 06/12/2019.
//  Copyright © 2019 Guillaume Louel. All rights reserved.
//

import Foundation
import AVFoundation
import AVKit

extension AerialView {
    func setupPlayerLayer(withPlayer player: AVPlayer) {
        let displayDetection = DisplayDetection.sharedInstance

        self.layer = CALayer()
        guard let layer = self.layer else {
            errorLog("\(self.description) Couldn't create CALayer")
            return
        }
        self.wantsLayer = true
        layer.backgroundColor = NSColor.black.cgColor
        layer.needsDisplayOnBoundsChange = true
        layer.frame = self.bounds
        debugLog("\(self.description) setting up player layer with bounds/frame: \(layer.bounds) / \(layer.frame)")

        playerLayer = AVPlayerLayer(player: player)

        // Fill/fit is only available in 10.10+
        if #available(OSX 10.10, *) {
            if PrefsDisplays.aspectMode == .fill {
                playerLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
            } else {
                playerLayer.videoGravity = AVLayerVideoGravity.resizeAspect
            }
        }
        playerLayer.autoresizingMask = [CAAutoresizingMask.layerWidthSizable, CAAutoresizingMask.layerHeightSizable]

        // In case of span mode we need to compute the size of our layer
        if PrefsDisplays.viewingMode == .spanned && !isPreview {
            let zRect = displayDetection.getZeroedActiveSpannedRect()
            debugLog("foundScreen check : \(foundScreen.debugDescription)")
            
            if let scr = foundScreen {
                let tRect = CGRect(x: zRect.origin.x - scr.zeroedOrigin.x,
                                   y: zRect.origin.y - scr.zeroedOrigin.y,
                                   width: zRect.width,
                                   height: zRect.height)
                debugLog("tRect : \(tRect)")
                playerLayer.frame = tRect
            } else {
                debugLog("This is an unknown screen in span mode, workarounding...")
                
                if let alternateScreen = DisplayDetection.sharedInstance.alternateFindScreenWith(frame: self.frame) {
                    foundScreen = alternateScreen
                    debugLog("📺 alternate screen found : \(alternateScreen.description)")
                    let tRect = CGRect(x: zRect.origin.x - alternateScreen.zeroedOrigin.x,
                                       y: zRect.origin.y - alternateScreen.zeroedOrigin.y,
                                       width: zRect.width,
                                       height: zRect.height)
                    playerLayer.frame = tRect
                } else {
                    errorLog("No alternate screen found, reverting to single screen mode")
                    playerLayer.frame = layer.bounds
                }
            }
        } else {
            playerLayer.frame = layer.bounds

            // "true" mirrored mode
            let index = AerialView.instanciatedViews.firstIndex(of: self) ?? 0
            if index % 2 == 1 && PrefsDisplays.viewingMode == .mirrored {
                playerLayer.transform = CATransform3DMakeAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
            }
        }
        layer.addSublayer(playerLayer)

        layer.contentsScale = (self.window?.backingScaleFactor) ?? 1.0
        self.playerLayer.contentsScale = (self.window?.backingScaleFactor) ?? 1.0

        
        // The layers for descriptions, clock, message
        // On Sonoma we can't use the reported frame!
        if foundFrame != nil {
            layerManager.setupExtraLayers(layer: layer, frame: foundFrame!)
        } else {
            layerManager.setupExtraLayers(layer: layer, frame: self.frame)
        }
        // Make sure we set the retinaness here
        layerManager.setContentScale(scale: self.window?.backingScaleFactor ?? 1.0)

        // An extra layer to try and contravent a macOS graphics driver bug
        // This is useful on High Sierra+ on Intel Macs
        if #available(macOS 12.0, *) {
        } else {
            setupGlitchWorkaroundLayer(layer: layer)
        }
   }

    // MARK: - AVPlayerItem Notifications

    @objc func playerItemFailedtoPlayToEnd(_ aNotification: Notification) {
        warnLog("\(self.description) AVPlayerItemFailedToPlayToEndTimeNotification \(aNotification)")
        playNextVideo()
    }

    @objc func playerItemNewErrorLogEntryNotification(_ aNotification: Notification) {
        warnLog("\(self.description) AVPlayerItemNewErrorLogEntryNotification \(aNotification)")
    }

    @objc func playerItemPlaybackStalledNotification(_ aNotification: Notification) {
        warnLog("\(self.description) AVPlayerItemPlaybackStalledNotification \(aNotification)")
    }

    @objc func playerItemDidReachEnd(_ aNotification: Notification) {
        debugLog("\(self.description) played did reach end")
        debugLog("\(self.description) notification: \(aNotification)")

        if shouldLoop {
            debugLog("Rewinding video!")
            if let playerItem = aNotification.object as? AVPlayerItem {
                playerItem.seek(to: CMTime.zero, completionHandler: nil)
            }
        } else {
            playNextVideo()
            debugLog("\(self.description) playing next video for player \(String(describing: player))")
        }

    }

    // Video fade-in/out
    func addPlayerFades(view: AerialView, player: AVPlayer, video: AerialVideo) {
        if !Aerial.helper.underCompanion {
            // We only fade in/out if we have duration
            if video.duration > 0 && AerialView.shouldFade && !shouldLoop {
                let playbackSpeed = Double(PlaybackSpeed.forVideo(video.id))

                view.playerLayer.opacity = 0
                let fadeAnimation = CAKeyframeAnimation(keyPath: "opacity")
                fadeAnimation.values = [0, 1, 1, 0] as [Int]
                fadeAnimation.keyTimes = [0,
                                          AerialView.fadeDuration/(video.duration/playbackSpeed),
                                          1-(AerialView.fadeDuration/(video.duration/playbackSpeed)), 1 ] as [NSNumber]

                fadeAnimation.duration = video.duration/playbackSpeed
                if #available(macOS 10.14, *) {
                    fadeAnimation.calculationMode = CAAnimationCalculationMode.cubic
                } else {
                    // Fallback on earlier versions
                }
                view.playerLayer.add(fadeAnimation, forKey: "mainfade")
            } else {
                view.playerLayer.opacity = 1.0
            }
        } else {
            view.playerLayer.opacity = 1.0
        }
    }

    func removePlayerFades() {
        self.playerLayer.removeAllAnimations()
        self.playerLayer.opacity = 1.0
    }
    
    // This works pre Catalina as of right now
    func setupGlitchWorkaroundLayer(layer: CALayer) {
        debugLog("Using dot workaround for video driver corruption")

        let workaroundLayer = CATextLayer()
        workaroundLayer.frame = self.bounds
        workaroundLayer.opacity = 1.0
        workaroundLayer.font = NSFont(name: "Helvetica Neue Medium", size: 4)
        workaroundLayer.fontSize = 4
        workaroundLayer.string = "."

        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key.font: workaroundLayer.font as Any]

        // Calculate bounding box
        let attrString = NSAttributedString(string: workaroundLayer.string as! String, attributes: attributes)
        let rect = attrString.boundingRect(with: layer.visibleRect.size, options: NSString.DrawingOptions.usesLineFragmentOrigin)

        workaroundLayer.frame = rect
        workaroundLayer.position = CGPoint(x: 2, y: 2)
        workaroundLayer.anchorPoint = CGPoint(x: 0, y: 0)
        layer.addSublayer(workaroundLayer)
    }
}
