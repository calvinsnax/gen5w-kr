# 무선 PhoneProjection 브리지 설치·복구

`gen5w.kr.bridge`는 순정 PhoneProjection에 무선 CarPlay 연결을 요청하고 상태를 확인하는 NEMESIS 모듈입니다. 제조사 APK/ODEX/Java 구현은 포함하지 않습니다. 자체 RFCOMM·iAP2·핫스팟 연결을 시작하지 않습니다. 이 모듈의 연결 요청과 실차 동작은 아직 차량에서 검증되지 않았습니다.

## 적용 조건

대상 파일은 설치 전에 전체 해시와 APK 조합을 검사합니다. `/system/app/Iap2ServerApp.odex`에는 순정 서비스 메서드를 바꾸는 구형 무선 제어 shim을 쓰지 않습니다. 한국 V035/V039에서 필요한 Wi-FiInformation·RouteGuidance capability 선언만 별도 레시피로 켜고, 원본 바이트를 소유 백업에 보존합니다. 이 capability가 없으면 iAP2가 RouteGuidance component를 광고하지 않아 Core가 차량 안내 데이터를 요청할 수 없습니다. 제거·실패 시 정확한 원본 ODEX로 복원합니다. `/system/app/HKMC_DiPO.odex`에는 독립된 핸들 통화 키 보완만 적용합니다. 순정 무선 receiver와 기존 무선 action 분기는 바꾸지 않습니다. V039의 `/system/app/HKMC_GPM.odex`는 Android Auto HUD용 패치를 적용합니다. 이 ODEX 수정들은 부팅 핵심 파일은 아니지만 시스템 앱 변경이며, 실차 검증과 되돌리기 준비가 필요합니다. APK는 수정하지 않습니다. 지원하지 않는 해시·교차 버전 조합은 설치 전 건너뛰고, 이미 소유한 파일이나 백업이 달라졌으면 덮어쓰지 않고 중단합니다.

helper는 `original FILE`, `patched FILE`, `apply IN OUT`, `verify FILE SHA`를 제공합니다. NEMESIS 추출 권한 0644를 고려하여 실행 전 우리 helper만 0755로 바꿉니다. 브리지 DEX와 호스트 APK가 있는지 설치 전에 확인합니다.

## 백업과 수명주기

- reset 유지 백업: `/system/etc/gen5w-kr-backup/bridge/{owner,original,dipooriginal,gpmoriginal}`.
- runtime 백업: `/data/nemesis/backup/gen5w.kr.bridge/{owner,original,dipooriginal,gpmoriginal}`.
- 소유 값: `gen5w.kr.bridge:v035-1` 또는 `gen5w.kr.bridge:v039-1`.
- 고정 stage: 각 ODEX 이름 뒤 `.gen5w-kr-bridge.tmp`.

설치 시 NEMESIS로 system을 rw로 remount한 뒤, 원본들을 모두 `cp -p`로 보관하고 전체 해시를 검증합니다. 백업은 임시 파일에서 검증한 뒤 rename합니다. 수정 결과도 helper로 검증한 뒤 원본 속성(mode/uid/gid)을 가진 stage에 쓰고 sync 후 rename합니다. stage 쓰기 직전에 durable staging 소유 표식도 sync하므로 중간 쓰기 이후 중단된 stage를 다음 실행에서 정리할 수 있습니다. 일부 파일만 수정된 상태에서 전원이 끊겼으면 소유한 원본 쌍을 확인하고 다음 설치에서 나머지를 완성합니다. 파일 적용에 실패하면 원본들로 rollback합니다. rollback 실패 시 원본들을 남기고 실패를 알립니다. 원본/수정본 target만 인정하며 알 수 없는 target은 자동 복구하지 않습니다. 종료 경로는 system을 ro로 되돌립니다.

재설치 시 원본 백업을 수정본으로 덮어쓰지 않습니다. `/data` reset으로 runtime 백업만 없어졌으면 system 백업으로 복구합니다. 제거는 원본 해시·소유 표식을 확인한 뒤 원본 bytes와 mode/uid/gid를 보존하여 복원하고 자기 백업만 제거합니다. 심볼릭 링크나 다른 소유 표식은 거부합니다. 이 경로에서 USB로 제조사 원본을 수집하지 않습니다.

단독(standalone) NEMESIS 설치는 거부합니다. 통합 설치는 재부팅 억제 표식을 만들고, 마지막에만 재부팅합니다. 변경한 Iap2ServerApp·DiPO·GPM과 관련된 Dalvik 최적화 캐시 항목을 지워 다음 부팅에서 현재 ODEX를 사용하게 합니다. `services.odex`, `SystemUI.odex`, framework, 커널, LK는 변경하지 않습니다. 단, 어떤 앱 ODEX 수정도 실차 부팅 안전성을 보장하지는 않습니다.

## 실행 구조

NEMESIS의 `scripts/service.sh`는 설치한 부팅부터 부팅 시도 수를 기록하고, 반복 실패 조건이 되면 확인된 원본 ODEX 복원을 시도합니다. 이 스크립트는 NEMESIS가 실행돼야 작동하므로 Android/NEMESIS가 시작되지 않는 고장까지 복구한다고 보장하지 않습니다. 부팅 완료 후 Android가 관리하는 `BridgeHostService`를 시작합니다. 앱은 저장된 같은 사용자 CarPlay 프로필이 활성화된 경우에만 순정 PhoneProjection 요청을 한 번 보내고 연결 상태를 관찰합니다. 자체 RFCOMM·iAP2 연결과 핫스팟 제어 broker는 시작하지 않습니다. 순정 서비스가 실행 중인지, 요청을 받는지, 휴대폰 Wi-Fi 접속 정보가 일치하는지는 실차에서 확인되지 않았습니다.

제거는 `/data/nemesis/gen5wkr.bridge.stopping`을 만든 뒤 `kr.gen5w.wireless.STOP_BRIDGE`를 방송하고 2초 기다립니다. 수신기는 `android.permission.SHUTDOWN`으로 보호됩니다. supervisor는 표식이 있으면 앱과 보조 프로세스를 중지하고 재시작하지 않습니다. 다음 설치가 성공한 뒤에만 표식을 지웁니다.

## 분리 시험 스위치 (진단용)

bridge 설치 후 CarPlay가 동작하지 않을 때 어느 ODEX 패치가 원인인지 가리기 위한 스위치입니다. USB 맨 바깥에 `GEN5W-BRIDGE-TEST` 파일을 두고 한 줄에 하나씩 적습니다.

| 값 | 효과 |
|---|---|
| `skip-iap2` | `Iap2ServerApp.odex`를 순정으로 둡니다. iAP2 Wi-Fi 정보·길안내 기능 선언이 켜지지 않으며, CarPlay HUD(core)는 설치 조건이 맞지 않아 건너뜁니다 |
| `skip-dipo` | `HKMC_DiPO.odex`를 순정으로 둡니다. 핸들 통화 키 보완이 빠집니다 |

설치기는 bridge를 설치하기 직전에 `/data/nemesis/gen5wkr.bridge.test`에 값을 기록하고, bridge의 설치 스크립트와 부팅 서비스가 같은 값을 읽습니다. 스위치 없이 다시 설치하면 표식을 지우고 일반 구성으로 패치합니다. 제거하면 표식도 지웁니다. 다른 값이 있으면 아무것도 바꾸지 않고 설치를 거부합니다. 원본 백업과 복원 절차는 일반 설치와 같습니다.

## PC 검증

`bash tests/bridge.sh`의 모의 설치·복원 및 supervisor 검사 164개가 통과했습니다. OEM 요청 세션·반사형 API 접근 JVM 시험도 포함됩니다. Android 4.4 차량의 PhoneProjection 권한, Wi-Fi 설정 일치, 무선 CarPlay는 아직 확인하지 않았습니다.
