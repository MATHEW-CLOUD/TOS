extension HLSStreamManager: FallbackHandlerDelegate {
    func fallbackHandler(_ handler: FallbackHandler, 
                        didActivateFallbackToVariant variant: HLSVariant) {
        // Update UI or notify observers
    }
    
    func fallbackHandler(_ handler: FallbackHandler, didRecover: Bool) {
        // Resume normal playback operations
    }
}
