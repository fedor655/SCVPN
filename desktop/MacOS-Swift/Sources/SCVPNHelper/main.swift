import SCVPNHelperKit

// Вся логика — в SCVPNHelperKit: тестовый таргет не может линковать
// executable, а логика демона обязана быть под проверками. Здесь остаётся
// только точка входа.
daemonMain(HelperEnv.fromEnvironment())
