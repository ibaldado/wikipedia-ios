import UIKit

extension UIScrollView {
    private var topOffsetY: CGFloat {
        return 0 - adjustedContentInset.top
    }

    private var bottomOffsetY: CGFloat {
        return contentSize.height - bounds.size.height + adjustedContentInset.bottom
    }

    private var topOffset: CGPoint {
        return CGPoint(x: contentOffset.x, y: topOffsetY)
    }

    private var bottomOffset: CGPoint {
        return CGPoint(x: contentOffset.x, y: bottomOffsetY)
    }

    public var isAtTop: Bool {
        return contentOffset.y <= topOffsetY
    }

    private var isAtBottom: Bool {
        return contentOffset.y >= bottomOffsetY
    }

    @objc(wmf_setContentInset:scrollIndicatorInsets:preserveContentOffset:preserveAnimation:)
    public func setContentInset(_ updatedContentInset: UIEdgeInsets, scrollIndicatorInsets updatedScrollIndicatorInsets: UIEdgeInsets, preserveContentOffset: Bool = true, preserveAnimation: Bool = false) -> Bool {
        guard updatedContentInset != contentInset || updatedScrollIndicatorInsets != scrollIndicatorInsets else {
            return false
        }
        let wasAtTop = isAtTop
        let wasAtBottom = isAtBottom
        scrollIndicatorInsets = updatedScrollIndicatorInsets

        if preserveAnimation {
            contentInset = updatedContentInset
        } else {
            let wereAnimationsEnabled = UIView.areAnimationsEnabled
            UIView.setAnimationsEnabled(false)
            contentInset = updatedContentInset
            UIView.setAnimationsEnabled(wereAnimationsEnabled)
        }
        
        guard preserveContentOffset else {
            return true
        }
        
        if wasAtTop {
            contentOffset = topOffset
        } else if contentSize.height > bounds.inset(by: adjustedContentInset).height && wasAtBottom {
            contentOffset = bottomOffset
        }
        
        return true
    }
}
