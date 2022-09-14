import Carbon
import Cocoa
import os

@MainActor
public class MachPortEventPublisher {
  @Published public internal(set) var event: MachPortEvent?

  required init() throws {}
}


public final class MachPortEventController: MachPortEventPublisher {
  private(set) public var eventSource: CGEventSource!

  private var machPort: CFMachPort!
  private var runLoopSource: CFRunLoopSource!
  private var lhs: Bool = true

  private let configuration: MachPortTapConfiguration

  public var isEnabled: Bool {
    get { machPort.map(CGEvent.tapIsEnabled) ?? false }
    set { machPort.map { CGEvent.tapEnable(tap: $0, enable: newValue) } }
  }

  required public init(_ eventSourceId: CGEventSourceStateID,
                       mode: CFRunLoopMode,
                       configuration: MachPortTapConfiguration = .init()) throws {
    self.configuration = configuration

    try super.init()

    let machPort = try createMachPort()

    self.eventSource = try CGEventSource.create(eventSourceId)
    self.machPort = machPort
    self.runLoopSource = try CFRunLoopSource.create(with: machPort)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, mode)
  }

  required init() throws {
    fatalError("init() has not been implemented")
  }

  private func callback(_ proxy: CGEventTapProxy, _ type: CGEventType,
                        _ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
    let result: Unmanaged<CGEvent>? = Unmanaged.passUnretained(cgEvent)
    if type == .flagsChanged {
      self.lhs = determineModifierKeysLocation(cgEvent)
    }

    let newEvent = MachPortEvent(event: cgEvent, eventSource: eventSource,
                                 lhs: self.lhs,
                                 type: type, result: result)

    if type != .flagsChanged {
      event = newEvent
    }

    return newEvent.result
  }

  // MARK: Private methods

  private func determineModifierKeysLocation(_ cgEvent: CGEvent) -> Bool {
    var result: Bool = true
    let emptyFlags = cgEvent.flags == CGEventFlags.maskNonCoalesced

    if !emptyFlags {
      let keyCode = cgEvent.getIntegerValueField(.keyboardEventKeycode)

      // Always return `true` if the function key is involved
      if keyCode == kVK_Function {
        return true
      }

      let rhs: [Int] = [kVK_RightCommand, kVK_RightOption, kVK_RightShift]
      result = !rhs.contains(Int(keyCode))
    } else if emptyFlags {
      result = true
    }

    return result
  }

  private func createMachPort() throws -> CFMachPort {
    let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
      | 1 << CGEventType.keyUp.rawValue
      | 1 << CGEventType.flagsChanged.rawValue
    let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

    guard let machPort = CGEvent.tapCreate(
      tap: configuration.location,
      place: configuration.place,
      options: configuration.options,
      eventsOfInterest: mask,
      callback: { proxy, type, event, userInfo in
        if let pointer = userInfo {
          let controller = Unmanaged<MachPortEventController>
            .fromOpaque(pointer)
            .takeUnretainedValue()
          return controller.callback(proxy, type, event)
        }
        return Unmanaged.passUnretained(event)
      }, userInfo: userInfo) else {
      throw MachPortError.failedToCreateMachPort
    }

    return machPort
  }
}
