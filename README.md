# orunhomework-ios-ci

옳은홈워크(ORUN HOMEWORK) iOS 앱의 **네이티브 껍데기 소스와 빌드 CI만** 담은 공개 저장소입니다.
웹앱(`nathankim6/orunhomework`)과 백엔드(Supabase) 소스는 비공개로 남아 있고 이 저장소에 복사하지 않았습니다.

앱은 웹 빌드를 안에 넣지 않고 **배포된 사이트를 그때그때 직접 엽니다.**
그래서 웹 UI를 고쳐 배포하면 앱스토어 재심사 없이, 앱 업데이트 없이 그대로 반영됩니다.

- 앱이 여는 주소: **https://orunhomework.com/** (학생 접속 링크·리포트 링크와 같은 정식 도메인)
- 번들 ID: `com.orunhomework.app` (앱스토어에 이미 올라가 있는 옳은홈워크와 같은 번들 — 업데이트로 이어짐)
- 앱 이름: 옳은홈워크 · iOS 15.0+ · iPhone/iPad

## 왜 재심사 없이 반영되나

| 단계 | 처리 |
| --- | --- |
| 웹 UI 수정 | `orunhomework` 저장소에서 평소처럼 배포 |
| 앱 실행 | 문서 요청을 `reloadIgnoringLocalCacheData` + `Cache-Control: no-cache`로 보내 항상 새 `index.html`을 받음 |
| 앱이 켜져 있을 때 | 포그라운드 복귀 시 배포본 지문(해시된 `/assets/index-*.js`)을 확인하고, 바뀐 경우에만 다시 불러옴 |
| 앱 업데이트 | 필요 없음. 네이티브 코드(권한 문구·동작)를 바꿀 때만 새 빌드 필요 |

안전장치:

- 녹음 중에는 절대 새로고침하지 않습니다(`getUserMedia` 사용 여부를 페이지에서 감지).
- 새로고침은 사이트 첫 화면(`/`)에 있을 때만 합니다. 학생이 과제를 작성 중인 하위 화면에서는 건드리지 않습니다.
- 로그인 세션(localStorage·쿠키)은 지우지 않습니다. 캐시만 네트워크 우선으로 다룹니다.

## 저장소 구성

```
native/ios/OrunHomework/          SwiftUI + WKWebView 앱 소스 (5개 파일)
native/ios/OrunHomework.xcodeproj  체크인된 Xcode 프로젝트 (스크립트로 재생성 가능)
native/ios/scripts/create-project.py   프로젝트·스킴 재생성
native/ios/scripts/verify.py           Xcode 없이 돌리는 정적 검증(plist·프로젝트·워크플로)
.github/workflows/ios-build.yml        서명 없는 시뮬레이터 빌드 (수동 실행)
.github/workflows/ios-simulator-smoke.yml  시뮬레이터 실행·스크린샷·프로세스 생존 확인
.github/workflows/ios-app-store.yml    Release 아카이브 → 서명된 IPA (수동 실행)
docs/ios-release.md                    출시 준비·검증 기록과 남은 관문
```

웹/백엔드 코드, Supabase 키, 학생 데이터, 인증서·프로비저닝 파일은 이 저장소에 없습니다.

## 로컬 빌드

```sh
xcodebuild -project native/ios/OrunHomework.xcodeproj -scheme OrunHomework \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath native/ios/build CODE_SIGNING_ALLOWED=NO build
```

정적 검증(Xcode 불필요):

```sh
python3 native/ios/scripts/verify.py
```

프로젝트 파일을 고칠 일이 있으면 손으로 고치지 말고 재생성하세요:

```sh
python3 native/ios/scripts/create-project.py
```

## GitHub Actions

- **iOS unsigned simulator build** — 서명 없는 시뮬레이터 `.app` 아티팩트. 제출·배포용이 아닙니다.
- **iOS simulator launch smoke** — 시뮬레이터에 설치·실행하고 스크린샷과 프로세스 생존을 남깁니다. 실기기 검증은 아닙니다.
- **Build signed App Store IPA** — 서명된 `.ipa` 아티팩트. 업로드·심사 제출은 하지 않습니다.

서명 워크플로에 필요한 저장소 시크릿(값은 커밋하지 않음):

| 시크릿 | 내용 |
| --- | --- |
| `IOS_DIST_CERT_P12_BASE64` | Apple Distribution 인증서(.p12) base64 |
| `IOS_DIST_CERT_PASSWORD` | 위 .p12 비밀번호 |
| `IOS_PROFILE_BASE64` | `com.orunhomework.app` App Store 프로비저닝 프로파일 base64 |

프로파일의 `application-identifier`가 `4RBXVT9Q86.com.orunhomework.app`인지 워크플로가 검사하고,
프로파일 이름은 파일에서 읽어 쓰므로 이름을 맞춰 넣을 필요가 없습니다.
