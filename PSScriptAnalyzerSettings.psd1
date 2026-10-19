@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # цветной вывод в консоль — это и есть интерфейс скрипта
        'PSAvoidUsingWriteHost',
        # пустые catch — сознательно: проверки «best effort», отсутствие данных выводится как «нет данных»
        'PSAvoidUsingEmptyCatchBlock'
    )
}
