export const UPDATE = Object.freeze({
  bundleId: 'com.mahmudcoding.net-conditioner',
  feedUrl:
    'https://github.com/mahmudcoding/net-conditioner/releases/latest/download/appcast.xml',
  githubRepo: 'mahmudcoding/net-conditioner',
  keychainAccount: 'com.mahmudcoding.net-conditioner',
  publicEdKey: 'OTzWAUHQziIeTZLrdxnjXy8XgkJ87RtnNwet9Zgq2Po=',
  scheduledCheckInterval: 86_400,
  sparkleVersion: '2.9.6',
  sparkleSha256: '52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192',
})

export const sparkleDownloadUrl = () =>
  `https://github.com/sparkle-project/Sparkle/releases/download/${UPDATE.sparkleVersion}/Sparkle-${UPDATE.sparkleVersion}.tar.xz`
