//
//  LoginView.swift
//  mochimix
//
//  Created by Chrissy Chien on 7/8/26.
//

import SwiftUI

/// Shown whenever the user isn't logged in to Spotify. Tapping the button
/// kicks off the PKCE login flow in SpotifyAuthService, which opens
/// Spotify's own login page in a secure system browser sheet.
struct LoginView: View {
    @ObservedObject var auth: SpotifyAuthService
    var lastError: String?
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            VStack(spacing: 12) {
                LoginLogoIconView()
                //AppHeaderView()
                Text("See what you've been playing on Spotify, \nright on your Home Screen.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            
            Spacer()
            
            if let lastError {
                Text(lastError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            
            Button {
                auth.startLogin()
            } label: {
                Text("Log in with Spotify")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background)
    }
    
    
    private struct LoginLogoIconView: View {
        @Environment(\.colorScheme) private var colorScheme
        
        private var imageName: String {
            colorScheme == .dark ? "login-logo-dark" : "login-logo-light"
        }
        
        var body: some View {
            Group {
                if let uiImage = UIImage(named: imageName) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                } else {
#if DEBUG
                    let _ = debugLog("Missing login logo asset named \(imageName). Check Assets.xcassets image set name and target membership.")
#endif
                    
                    Image(systemName: "music.note.list")
                        .font(.system(size: 400))
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
            .frame(width: 400, height: 200)
            .padding(.bottom, 12)
        }
    }
}
