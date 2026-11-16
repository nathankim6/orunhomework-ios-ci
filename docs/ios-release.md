# 옳은홈워크 iOS 출시 준비 기록

## 1. 확인된 사실 (2026-11-16)

| 항목 | 값 | 근거 |
| --- | --- | --- |
| 앱스토어 앱 | 옳은홈워크 (id6827193073), 개발자 Seongjin Kim, Education, 4+ | App Store 조회 API |
| 번들 ID | `com.orunhomework.app` | App Store 조회 API `bundleId` |
| 현재 버전 | 1.0.1 (2026-11-11), 최초 출시 2026-11-04, 최소 iOS 15.0 | App Store 조회 API |
| 라이브 웹 주소 | `https://orunhomework.com/` — HTTP 200 (Netlify Edge) | `curl -I`, 2026-11-16 |
| 미러 | `https://orunhomework.vercel.app` — 같은 빌드(같은 CSS 해시) | `curl -I` + 본문 대조 |
| `www` | 301 → `https://orunhomework.com/` | `curl -I` |
| 웹앱 정식 주소 | `SITE_URL = "https://orunhomework.com"`, 리포트 링크 `/r/<token>` | `orunhomework` 소스 |
| 팀 ID | `4RBXVT9Q86` (옳은VOCA와 동일 Apple Developer 팀) | `orunvoca-ios-ci` 서명 워크플로 |

이번 저장소의 앱은 **1.0.1의 후속 빌드**로 올리는 것을 전제로 `MARKETING_VERSION = 1.1.0`,
`CURRENT_PROJECT_VERSION = 1`에서 시작합니다. 앱스토어 커넥트에 이미 1.0.1 기록이 있으므로
다음 업로드 빌드 번호는 1보다 커야 합니다(워크플로 입력값으로 지정).

## 2. 이 껍데기가 하는 일

- `https://orunhomework.com/`만 표시합니다. 다른 도메인 링크는 `SFSafariViewController`로 넘기고,
  `tel:`·`mailto:`는 시스템에 넘깁니다. 서브프레임(유튜브 리뷰 영상 임베드)은 브라우저처럼 허용합니다.
- 세션은 `WKWebsiteDataStore.default()`에 남겨 앱을 껐다 켜도 접속 코드 로그인이 유지됩니다.
- 문서 요청은 네트워크 우선(`reloadIgnoringLocalCacheData`, `Cache-Control: no-cache`).
  해시된 `/assets/*`는 불변이므로 디스크 캐시를 그대로 씁니다.
- 포그라운드 복귀 시 첫 화면에 한해 배포본 지문을 60초 간격으로 확인하고, 바뀐 경우에만 다시 불러옵니다.
  녹음 중이거나 하위 화면에 있으면 새로고침하지 않습니다.
- 웹 프로세스가 종료되면(`webViewWebContentProcessDidTerminate`) 다시 불러옵니다.

## 3. 권한과 설정

| Info.plist 키 | 값 | 이유 |
| --- | --- | --- |
| `NSMicrophoneUsageDescription` | 숙제 음성을 녹음해 제출할 때 마이크를 사용합니다… | 학생 녹음 화면(`getUserMedia`) |
| `NSCameraUsageDescription` | 숙제 사진을 찍어 제출할 때 카메라를 사용합니다. | 사진 과제 촬영(`input[type=file] capture`) |
| `NSPhotoLibraryUsageDescription` | 숙제 사진을 사진 보관함에서 골라 제출할 때 사용합니다. | 사진 선택 업로드 |
| `UIStatusBarStyle` + `UIViewControllerBasedStatusBarAppearance=false` | 라이트 컨텐츠 | 사이트 배경(#0F172A) 위 흰 상태바 |
| `UILaunchScreen.UIColorName` | LaunchBackground(#0F172A) | 실행 시 흰 화면 번쩍임 방지 |
| `ITSAppUsesNonExemptEncryption` | false | 표준 HTTPS만 사용 |

- 마이크: `AVAudioSession`을 `.playAndRecord` + `.defaultToSpeaker` + `.allowBluetooth` + `.mixWithOthers`로
  앱 시작 시 미리 설정합니다(활성화는 WebKit이 녹음 시작 시). 이 설정이 없으면 녹음이 수화부로 가라앉거나
  첫 녹음이 실패하는 사례가 있습니다.
- 캡처 권한은 `WKUIDelegate.requestMediaCapturePermissionFor`에서 **신뢰 오리진(orunhomework.com)에만** 부여합니다.
  시스템 마이크 권한 팝업은 그대로 뜹니다.
- Safe Area: 웹뷰를 세이프 에어리어 안에 두고(사이트가 `viewport-fit=cover`가 아님) 바깥은 사이트 배경색으로 채웁니다.
  노치·홈 인디케이터에 글자가 가리지 않고, 하단이 잘리지 않습니다.
- 파일: 교사 리포트 같은 서버 첨부 파일은 웹뷰 쿠키를 그대로 실은 `URLSession` 다운로드로, 페이지가 만든 blob/data 파일은
  페이지 브리지로 받아 둘 다 공유 시트로 넘깁니다. 단일 파일 40MB·오리진 검사·이름 정리·시간 제한이 걸려 있습니다.

## 4. 검증 상태

- `python3 native/ios/scripts/verify.py`: 81개 항목 통과(plist·프라이버시 매니페스트·에셋 JSON·pbxproj·스킴·워크플로).
- `iOS unsigned simulator build` #43816376177: **success** — Swift 전체 컴파일, 코드 경고 없음.
- `iOS simulator launch smoke` #43816586913: **success** — 시뮬레이터에 설치·실행 후 35초 시점 스크린샷에
  라이브 사이트의 로그인 화면(ORUN HOMEWORK, 치이카와 테마, 접속 코드 입력)이 실제로 렌더링되었고 프로세스도 살아 있었습니다.
  실기기 검증은 아닙니다.
- **미검증**: 실제 아이폰에서의 녹음 음량·권한 팝업, 카메라/사진 선택, 파일 공유, iPad 레이아웃,
  App Store Connect 업로드·심사. 이 문서는 출시 승인을 주장하지 않습니다.

## 5. 사용자가 해야 할 일

1. 저장소 시크릿 3개 등록: `IOS_DIST_CERT_P12_BASE64`, `IOS_DIST_CERT_PASSWORD`, `IOS_PROFILE_BASE64`.
   - 인증서는 `orunvoca-ios-ci`에 넣은 것과 같은 Apple Distribution 인증서를 그대로 쓰면 됩니다.
   - 프로파일은 **`com.orunhomework.app`용 App Store 프로파일**이어야 합니다(옳은VOCA 프로파일 아님).
     기존 1.0.1을 올릴 때 쓴 프로파일이 그대로 유효하면 그것을 base64로 넣으면 됩니다.
2. `Build signed App Store IPA`를 build_number와 함께 실행하고, 나온 `.ipa`를 Xcode Organizer/Transporter로 업로드.
3. 실기기(아이폰)에서 녹음·사진·로그인을 한 번 확인한 뒤 심사 제출.

## 6. 남은 심사 관문

- App Review 4.2(최소 기능): 웹뷰만 표시하는 앱은 반려 위험이 있습니다. 현재 앱스토어에 같은 방식의
  1.0.1이 이미 게시되어 있으므로 위험은 낮지만, 심사 노트에 "학교 숙제 제출 서비스의 공식 앱"이라는 점과
  접속 코드가 필요하다는 점, 리뷰용 계정을 제공해야 합니다.
- App Privacy 답변은 기존 게시본과 일치해야 합니다. 네이티브 껍데기 자체는 아무 데이터도 수집하지 않지만
  (`PrivacyInfo.xcprivacy` 참조), 웹 서비스가 수집하는 항목은 기존 라벨을 유지해야 합니다.
- 스크린샷은 실제 빌드에서 새로 찍어야 합니다(기존 스크린샷은 이전 UI일 수 있음).
