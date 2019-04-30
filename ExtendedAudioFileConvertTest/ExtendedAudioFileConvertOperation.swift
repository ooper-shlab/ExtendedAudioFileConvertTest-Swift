//
//  ExtendedAudioFileConvertOperation.swift
//  ExtendedAudioFileConvertTest
//
//  Translated by OOPer in cooperation with shlab.jp, on 2017/1/7.
//
//
/*
    Copyright (C) 2016 Apple Inc. All Rights Reserved.
    See LICENSE.txt for this sample’s licensing information

    Abstract:
    Demonstrates converting audio using ExtAudioFile.
 */

import Foundation
import AudioToolbox
import Darwin
import AVFoundation

@objc(ExtendedAudioFileConvertOperationDelegate)
protocol ExtendedAudioFileConvertOperationDelegate: NSObjectProtocol {
    
    @objc(audioFileConvertOperation:didEncounterError:)
    func audioFileConvertOperation(_ audioFileConvertOperation: ExtendedAudioFileConvertOperation, didEncounterError error: Error)
    
    @objc(audioFileConvertOperation:didCompleteWithURL:)
    func audioFileConvertOperation(_ audioFileConvertOperation: ExtendedAudioFileConvertOperation, didCompleteWith destinationURL: URL)
    
}

//MARK:- Convert
// our own error code when we cannot continue from an interruption
private extension OSStatus {
    static let kMyAudioConverterErr_CannotResumeFromInterruptionError = OSStatus("CANT" as FourCharCode)
}

private enum AudioConverterState: Int {
    case initial
    case running
    case paused
    case done
}

@objc(ExtendedAudioFileConvertOperation)
class ExtendedAudioFileConvertOperation: Operation {
    
    let sourceURL: URL
    
    let destinationURL: URL
    
    let sampleRate: Float64
    
    let outputFormat: AudioFormatID
    
    weak var delegate: ExtendedAudioFileConvertOperationDelegate?
    
    // MARK: Properties
    
    private var queue: DispatchQueue = DispatchQueue(label: "com.example.apple-samplecode.ExtendedAudioFileConvertTest.ExtendedAudioFileConvertOperation.queue", attributes: .concurrent)
    
    private var semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
    
    private var state: AudioConverterState = .initial
    
    // MARK: Initialization
    
    init(sourceURL: URL, destinationURL: URL, sampleRate: Float64, outputFormat: AudioFormatID) {
        
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.sampleRate = sampleRate
        self.outputFormat = outputFormat
        
        super.init()
        
        NotificationCenter.default.addObserver(self, selector: #selector(handleAudioSessionInterruptionNotification), name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance())
        
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance())
    }
    
    override func main() {
        super.main()
        
        // This should never run on the main thread.
        assert(!Thread.isMainThread)
        
        // Set the state to running.
        
        self.queue.sync {[weak self] in
            self?.state = .running
        }
        
        var error: OSStatus = noErr
        do {//### for cleanup `defer`s
            var _sourceFile: ExtAudioFileRef? = nil
            var _destinationFile: ExtAudioFileRef? = nil
            var converter: AudioConverterRef? = nil
            defer {
                //### Seems disposing order affects...
                if _destinationFile != nil {ExtAudioFileDispose(_destinationFile!)}
                if _sourceFile != nil {ExtAudioFileDispose(_sourceFile!)}
                if converter != nil {AudioConverterDispose(converter!)}
            }
            // Get the source files.
            
            guard checkError(ExtAudioFileOpenURL(self.sourceURL as CFURL, &_sourceFile), withError: "ExtAudioFileOpenURL failed for sourceFile with URL: \(self.sourceURL)"),
                let sourceFile = _sourceFile else {
                    return
            }
            
            // Get the source data format.
            var sourceFormat = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout.stride(ofValue: sourceFormat))
            
            guard checkError(ExtAudioFileGetProperty(sourceFile, kExtAudioFileProperty_FileDataFormat, &size, &sourceFormat), withError: "ExtAudioFileGetProperty couldn't get the source data format") else {
                return
            }
            
            // Setup the output file format.
            var destinationFormat = AudioStreamBasicDescription()
            destinationFormat.mSampleRate = (self.sampleRate == 0 ? sourceFormat.mSampleRate : self.sampleRate)
            
            if self.outputFormat == kAudioFormatLinearPCM {
                // If the output format is PCM, create a 16-bit file format description.
                destinationFormat.mFormatID = self.outputFormat
                destinationFormat.mChannelsPerFrame = sourceFormat.mChannelsPerFrame
                destinationFormat.mBitsPerChannel = 16
                destinationFormat.mBytesPerFrame = 2 * destinationFormat.mChannelsPerFrame
                destinationFormat.mBytesPerPacket = destinationFormat.mBytesPerFrame
                destinationFormat.mFramesPerPacket = 1
                destinationFormat.mFormatFlags = kLinearPCMFormatFlagIsPacked | kLinearPCMFormatFlagIsSignedInteger // little-endian
            } else {
                // This is a compressed format, need to set at least format, sample rate and channel fields for kAudioFormatProperty_FormatInfo.
                destinationFormat.mFormatID = self.outputFormat
                
                // For iLBC, the number of channels must be 1.
                destinationFormat.mChannelsPerFrame = (self.outputFormat == kAudioFormatiLBC ? 1 : sourceFormat.mChannelsPerFrame)
                
                // Use AudioFormat API to fill out the rest of the description.
                size = UInt32(MemoryLayout.stride(ofValue: destinationFormat))
                guard checkError(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &destinationFormat), withError: "AudioFormatGetProperty couldn't fill out the destination data format") else {
                    return
                }
            }
            
            print("Source file format:")
            ExtendedAudioFileConvertOperation.printAudioStreamBasicDescription(sourceFormat)
            print("Destination file format:")
            ExtendedAudioFileConvertOperation.printAudioStreamBasicDescription(destinationFormat)
            
            // Create the destination audio file.
            print(destinationURL.path)
            guard checkError(ExtAudioFileCreateWithURL(self.destinationURL as CFURL, kAudioFileCAFType, &destinationFormat, nil, UInt32(AudioFileFlags.eraseFile.rawValue), &_destinationFile), withError: "ExtAudioFileCreateWithURL failed!"),
                let destinationFile = _destinationFile else {
                    return
            }
            
            /*
             set the client format - The format must be linear PCM (kAudioFormatLinearPCM)
             You must set this in order to encode or decode a non-PCM file data format
             You may set this on PCM files to specify the data format used in your calls to read/write
             */
            var clientFormat = AudioStreamBasicDescription()
            if self.outputFormat == kAudioFormatLinearPCM {
                clientFormat = destinationFormat
            } else {
                
                clientFormat.mFormatID = kAudioFormatLinearPCM
                let sampleSize = UInt32(MemoryLayout<Int32>.size)
                clientFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked
                clientFormat.mBitsPerChannel = 8 * sampleSize
                clientFormat.mChannelsPerFrame = sourceFormat.mChannelsPerFrame
                clientFormat.mFramesPerPacket = 1
                clientFormat.mBytesPerFrame = sourceFormat.mChannelsPerFrame * sampleSize
                clientFormat.mBytesPerPacket = clientFormat.mBytesPerFrame
                clientFormat.mSampleRate = sourceFormat.mSampleRate
            }
            
            print("Client file format:")
            ExtendedAudioFileConvertOperation.printAudioStreamBasicDescription(clientFormat)
            
            size = UInt32(MemoryLayout.stride(ofValue: clientFormat))
            guard checkError(ExtAudioFileSetProperty(sourceFile, kExtAudioFileProperty_ClientDataFormat, size, &clientFormat), withError: "Couldn't set the client format on the source file!") else {
                return
            }
            
            size = UInt32(MemoryLayout.stride(ofValue: clientFormat))
            guard checkError(ExtAudioFileSetProperty(destinationFile, kExtAudioFileProperty_ClientDataFormat, size, &clientFormat), withError: "Couldn't set the client format on the destination file!") else {
                return
            }
            
            // Get the audio converter.
            
            size = UInt32(MemoryLayout.stride(ofValue: converter))
            guard checkError(ExtAudioFileGetProperty(destinationFile, kExtAudioFileProperty_AudioConverter, &size, &converter), withError: "Failed to get the Audio Converter from the destination file.") else {
                return
            }
            
            /*
             Can the Audio Converter resume after an interruption?
             this property may be queried at any time after construction of the Audio Converter (which in this case is owned by an ExtAudioFile object) after setting its output format
             there's no clear reason to prefer construction time, interruption time, or potential resumption time but we prefer
             construction time since it means less code to execute during or after interruption time.
             */
            var canResumeFromInterruption = true
            var canResume: UInt32 = 0
            size = UInt32(MemoryLayout.stride(ofValue: canResume))
            //### `converter` is nil, in case of LPCM.
            if let converter = converter {
                error = AudioConverterGetProperty(converter, kAudioConverterPropertyCanResumeFromInterruption, &size, &canResume)
            } else {
                //### Original Objective-C code expects `kAudio_ParamError` when `converter` is nil.
                error = kAudio_ParamError
            }
            
            if error == noErr {
                /*
                 we recieved a valid return value from the GetProperty call
                 if the property's value is 1, then the codec CAN resume work following an interruption
                 if the property's value is 0, then interruptions destroy the codec's state and we're done
                 */
                
                canResumeFromInterruption = (canResume != 0)
                
                print("Audio Converter \(!canResumeFromInterruption ? "CANNOT" : "CAN") continue after interruption!")
                
            } else {
                /*
                 if the property is unimplemented (kAudioConverterErr_PropertyNotSupported, or paramErr returned in the case of PCM),
                 then the codec being used is not a hardware codec so we're not concerned about codec state
                 we are always going to be able to resume conversion after an interruption
                 */
                
                if error == kAudioConverterErr_PropertyNotSupported {
                    print("kAudioConverterPropertyCanResumeFromInterruption property not supported - see comments in source for more info.")
                    
                } else {
                    print("AudioConverterGetProperty kAudioConverterPropertyCanResumeFromInterruption result \(error), paramErr is OK if PCM")
                }
                
                error = noErr
            }
            
            // Setup buffers
            let bufferByteSize = 32768
            var sourceBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferByteSize)
            defer {sourceBuffer.deallocate()}
            
            /*
             keep track of the source file offset so we know where to reset the source for
             reading if interrupted and input was not consumed by the audio converter
             */
            var sourceFrameOffset: Int64 = 0
            
            // Do the read and write - the conversion is done on and by the write call.
            print("Converting...")
            while true {
                // Set up output buffer list.
                var fillBufferList = AudioBufferList()
                fillBufferList.mNumberBuffers = 1
                fillBufferList.mBuffers.mNumberChannels = clientFormat.mChannelsPerFrame
                fillBufferList.mBuffers.mDataByteSize = UInt32(bufferByteSize)
                fillBufferList.mBuffers.mData = UnsafeMutableRawPointer(sourceBuffer)
                
                /*
                 The client format is always linear PCM - so here we determine how many frames of lpcm
                 we can read/write given our buffer size
                 */
                var numberOfFrames: UInt32 = 0
                if clientFormat.mBytesPerFrame > 0 {
                    // Handles bogus analyzer divide by zero warning mBytesPerFrame can't be a 0 and is protected by an Assert.
                    numberOfFrames = UInt32(bufferByteSize) / clientFormat.mBytesPerFrame
                }
                
                guard checkError(ExtAudioFileRead(sourceFile, &numberOfFrames, &fillBufferList), withError: "ExtAudioFileRead failed!") else {
                    return
                }
                
                if numberOfFrames == 0 {
                    // This is our termination condition.
                    error = noErr
                    break
                }
                
                sourceFrameOffset += Int64(numberOfFrames)
                
                let wasInterrupted = self.checkIfPausedDueToInterruption()
                
                if (error != noErr || wasInterrupted) && !canResumeFromInterruption {
                    // this is our interruption termination condition
                    // an interruption has occured but the Audio Converter cannot continue
                    error = .kMyAudioConverterErr_CannotResumeFromInterruptionError
                    break
                }
                
                error = ExtAudioFileWrite(destinationFile, numberOfFrames, &fillBufferList)
                // If we were interrupted in the process of the write call, we must handle the errors appropriately.
                if error != noErr {
                    if error == kExtAudioFileError_CodecUnavailableInputConsumed {
                        print("ExtAudioFileWrite kExtAudioFileError_CodecUnavailableInputConsumed error \(error)")
                        
                        /*
                         Returned when ExtAudioFileWrite was interrupted. You must stop calling
                         ExtAudioFileWrite. If the underlying audio converter can resume after an
                         interruption (see kAudioConverterPropertyCanResumeFromInterruption), you must
                         wait for an EndInterruption notification from AudioSession, then activate the session
                         before resuming. In this situation, the buffer you provided to ExtAudioFileWrite was successfully
                         consumed and you may proceed to the next buffer
                         */
                    } else if error == kExtAudioFileError_CodecUnavailableInputNotConsumed {
                        print("ExtAudioFileWrite kExtAudioFileError_CodecUnavailableInputNotConsumed error \(error)")
                        
                        /*
                         Returned when ExtAudioFileWrite was interrupted. You must stop calling
                         ExtAudioFileWrite. If the underlying audio converter can resume after an
                         interruption (see kAudioConverterPropertyCanResumeFromInterruption), you must
                         wait for an EndInterruption notification from AudioSession, then activate the session
                         before resuming. In this situation, the buffer you provided to ExtAudioFileWrite was not
                         successfully consumed and you must try to write it again
                         */
                        
                        // seek back to last offset before last read so we can try again after the interruption
                        sourceFrameOffset -= Int64(numberOfFrames)
                        guard checkError(ExtAudioFileSeek(sourceFile, sourceFrameOffset), withError: "ExtAudioFileSeek failed!") else {
                            return
                        }
                    } else {
                        _ = self.checkError(error, withError: "ExtAudioFileWrite failed!")
                        return
                    }
                }
            }
            
            // Cleanup
            //### see `defer` in this do-block
        }
        
        // Set the state to done.
        self.queue.sync {[weak self] in
            self?.state = .done
        }
        
        if error == noErr {
            self.delegate?.audioFileConvertOperation(self, didCompleteWith: self.destinationURL)
        }
    }
    
    private func checkError(_ error: OSStatus, withError string: @autoclosure ()->String) -> Bool{
        if error == noErr {
            return true
        }
        
        let err = NSError(domain: "AudioFileConvertOperationErrorDomain", code: Int(error), userInfo: [NSLocalizedDescriptionKey: string()])
        self.delegate?.audioFileConvertOperation(self, didEncounterError: err)
        
        return false
    }
    
    private func checkIfPausedDueToInterruption() -> Bool {
        var wasInterrupted = false
        
        self.queue.sync {[weak self] in
            assert(self?.state != .done)
            
            while self?.state == .paused {
                self?.semaphore.wait()
                
                wasInterrupted = true
            }
        }
        
        // We must be running or something bad has happened.
        assert(self.state == .running)
        
        return wasInterrupted
    }
    
    // MARK: Notification Handlers.
    
    @objc func handleAudioSessionInterruptionNotification(_ notification: NSNotification) {
        let interruptionType = AVAudioSession.InterruptionType(rawValue: notification.userInfo![AVAudioSessionInterruptionTypeKey] as! UInt)!
        
        print("Session interrupted > --- \(interruptionType == .began ? "Begin Interruption" : "End Interruption") ---")
        
        if interruptionType == .began {
            self.queue.sync {[weak self] in
                if self?.state == .running {
                    self?.state = .paused
                }
            }
        } else {
            
            do {
                
                try AVAudioSession.sharedInstance().setActive(true)
                
            } catch let error {
                NSLog("AVAudioSession setActive failed with error: \(error.localizedDescription)")
            }
            
            
            if self.state == .paused {
                self.semaphore.signal()
            }
            
            self.queue.sync {[weak self] in
                self?.state = .running
            }
        }
    }
    
    static func printAudioStreamBasicDescription(_ asbd: AudioStreamBasicDescription) {
        print(String(format: "Sample Rate:         %10.0f",  asbd.mSampleRate))
        print(String(format: "Format ID:                 \(asbd.mFormatID.fourCharString)"))
        print(String(format: "Format Flags:        %10X",    asbd.mFormatFlags))
        print(String(format: "Bytes per Packet:    %10d",    asbd.mBytesPerPacket))
        print(String(format: "Frames per Packet:   %10d",    asbd.mFramesPerPacket))
        print(String(format: "Bytes per Frame:     %10d",    asbd.mBytesPerFrame))
        print(String(format: "Channels per Frame:  %10d",    asbd.mChannelsPerFrame))
        print(String(format: "Bits per Channel:    %10d",    asbd.mBitsPerChannel))
        print()
    }
    
}
