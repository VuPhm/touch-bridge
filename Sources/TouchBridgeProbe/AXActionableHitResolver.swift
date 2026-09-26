import Foundation
import CoreGraphics
import ApplicationServices

struct ActionableAXNode {
    let id: Int
    let role: String
    let supportedActions: Set<String>
    let settableAttributes: Set<String>
    let frame: CGRect?
    var children: [Int]
}

struct ActionableAXResolution {
    let nodeID: Int
    let depth: Int
    let nodesVisited: Int
}

struct AXActionableHitResolution {
    let element: AXUIElement?
    let node: AXNodeCapability?
    let depth: Int?
    let nodesVisited: Int

    var found: Bool { element != nil && node != nil }
}

enum AXActionableHitResolver {
    static let maximumDepth = 6
    static let maximumNodes = 64
    static let timeBudgetSeconds = 0.030

    /// Pure bounded graph resolver, shared by live AX traversal and runtime tests.
    static func resolve(rootID: Int, nodes: [Int: ActionableAXNode], point: CGPoint, maximumDepth: Int = maximumDepth, maximumNodes: Int = maximumNodes) -> ActionableAXResolution? {
        guard nodes[rootID] != nil else { return nil }
        var queue: [(id: Int, depth: Int)] = [(rootID, 0)]
        var cursor = 0
        var visited = Set<Int>()
        var candidates: [(nodeID: Int, depth: Int, area: CGFloat, order: Int)] = []

        while cursor < queue.count, visited.count < maximumNodes {
            let (id, depth) = queue[cursor]
            cursor += 1
            guard visited.insert(id).inserted, let node = nodes[id] else { continue }
            let containing = node.frame?.contains(point) ?? (depth == 0)
            if containing && TapRoutingPolicy.isPrimaryActionable(
                role: node.role,
                supportedActions: node.supportedActions,
                settableAttributes: node.settableAttributes
            ) {
                let area = node.frame.map { max(0, $0.width) * max(0, $0.height) } ?? .greatestFiniteMagnitude
                candidates.append((id, depth, area, candidates.count))
            }
            guard depth < maximumDepth else { continue }
            for childID in node.children where queue.count < maximumNodes {
                queue.append((childID, depth + 1))
            }
        }

        // Deepest meaningful target wins, then the smallest containing frame,
        // then stable traversal order for deterministic ties.
        return candidates.sorted {
            if $0.depth != $1.depth { return $0.depth > $1.depth }
            if $0.area != $1.area { return $0.area < $1.area }
            return $0.order < $1.order
        }.first.map { ActionableAXResolution(nodeID: $0.nodeID, depth: $0.depth, nodesVisited: visited.count) }
    }

    /// Walk only the initial hit element's local descendant neighborhood.
    static func resolve(initialElement: AXUIElement, point: CGPoint) -> AXActionableHitResolution {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let rawCapability = AXCapabilityInspector.shared.inspectNode(initialElement)
        var liveActionsRef: CFArray?
        var liveActionsError = AXUIElementCopyActionNames(initialElement, &liveActionsRef)
        if liveActionsError == .cannotComplete {
            var retryActionsRef: CFArray?
            let retryError = AXUIElementCopyActionNames(initialElement, &retryActionsRef)
            if retryError == .success, retryActionsRef as? [String] != nil {
                liveActionsRef = retryActionsRef
                liveActionsError = .success
                TouchBridgeLogger.info(.semantic, "RAW_ACTIONABLE_RETRY -> AX actions available")
            } else {
                liveActionsError = retryError
                TouchBridgeLogger.info(.semantic, "RAW_ACTIONABLE_REJECTED: action_query_failed (retry error \(retryError.rawValue))")
            }
        }
        let liveActions = liveActionsError == .success
            ? Set((liveActionsRef as? [String]) ?? [])
            : Set<String>()
        let rawFrame: CGRect?
        if let position = rawCapability.position, let size = rawCapability.size,
           position.count >= 2, size.count >= 2, size[0] > 0, size[1] > 0 {
            rawFrame = CGRect(x: position[0], y: position[1], width: size[0], height: size[1])
        } else {
            rawFrame = nil
        }
        if liveActionsError != .success {
            TouchBridgeLogger.info(.semantic, "RAW_ACTIONABLE_REJECTED: action_query_failed")
        } else if rawFrame?.contains(point) == false {
            TouchBridgeLogger.info(.semantic, "RAW_ACTIONABLE_REJECTED: frame_miss")
        } else if TapRoutingPolicy.isPrimaryActionable(
            role: rawCapability.role,
            supportedActions: liveActions,
            settableAttributes: Set(rawCapability.settableAttributes)
        ) {
            let freshNode = rawCapability.replacingSupportedActions(Array(liveActions))
            TouchBridgeLogger.info(.semantic, "RAW_ACTIONABLE_ACCEPTED: \(rawCapability.role)")
            return AXActionableHitResolution(element: initialElement, node: freshNode, depth: 0, nodesVisited: 1)
        } else {
            TouchBridgeLogger.info(.semantic, "RAW_ACTIONABLE_REJECTED: role_or_primary_action")
        }

        var elements: [AXUIElement] = [initialElement]
        var nodes: [Int: ActionableAXNode] = [:]
        var queue: [(id: Int, depth: Int)] = [(0, 0)]
        var cursor = 0

        while cursor < queue.count,
              elements.count <= maximumNodes,
              ProcessInfo.processInfo.systemUptime - startedAt < timeBudgetSeconds {
            let (nodeID, depth) = queue[cursor]
            cursor += 1
            let element = elements[nodeID]
            let capability = AXCapabilityInspector.shared.inspectNode(element)
            let frame: CGRect?
            if let position = capability.position, let size = capability.size,
               position.count >= 2, size.count >= 2, size[0] > 0, size[1] > 0 {
                frame = CGRect(x: position[0], y: position[1], width: size[0], height: size[1])
            } else {
                frame = nil
            }

            var node = ActionableAXNode(
                id: nodeID,
                role: capability.role,
                supportedActions: Set(capability.supportedActions),
                settableAttributes: Set(capability.settableAttributes),
                frame: frame,
                children: []
            )

            if depth < maximumDepth, elements.count < maximumNodes {
                var childrenRef: CFArray?
                let remaining = maximumNodes - elements.count
                if AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, remaining, &childrenRef) == .success,
                   let children = childrenRef as? [AnyObject] {
                    for childObject in children {
                        guard elements.count < maximumNodes else { break }
                        let child = childObject as! AXUIElement
                        let childID = elements.count
                        elements.append(child)
                        node.children.append(childID)
                        queue.append((childID, depth + 1))
                    }
                }
            }
            nodes[nodeID] = node
        }

        let selected = resolve(rootID: 0, nodes: nodes, point: point)
        guard let selected, selected.nodeID < elements.count else {
            return AXActionableHitResolution(element: nil, node: nil, depth: nil, nodesVisited: nodes.count)
        }
        let resolvedElement = elements[selected.nodeID]
        return AXActionableHitResolution(
            element: resolvedElement,
            node: AXCapabilityInspector.shared.inspectNode(resolvedElement),
            depth: selected.depth,
            nodesVisited: nodes.count
        )
    }
}
