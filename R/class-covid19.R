#' R6 Covid-19 Class
#'
#' @description
#' This object type is used to retrieve, analyse and plot international data on
#' COVID19 outbreak and spreading.
#'
#' @param region is a string; the name of the region to be returned.
#' Use "ITA" to return the national aggregated data.
#' @param series is a string; the name of the field that has to be considered.
#' @param fit_date is a date; it is the end of the historical time series used
#' to produce the forecasts.
#' @param end_date is a date; it is the end of the forecast period.
#' @param log is a boolean; if \code{TRUE}, a logarithmic scale is applied to y
#' axis in plots.
#'
#' @import highcharter
#' @export
Covid <- R6::R6Class(

    # Class Covid ----
    classname = 'Covid',

    # * Public Members ----
    public = list(

        #' @description
        #' Create a new Covid object.
        initialize = function() {
            invisible(self)
        },

        #' @description
        #' This is to print the object type.
        print = function() {
            cat('Covid19 Class Object.\n')
        },

        #' @description
        #' This returns the table with raw data.
        get = function(region = NULL) {
            if (is.null(private$tab)) self$update()
            if (is.null(region)) {
                private$tab
            } else if (region == 'ITA') {
                private$tab %>%
                    dplyr::select(-denominazione_regione) %>%
                    dplyr::group_by(data) %>%
                    dplyr::summarise_all(sum)
            } else {
                private$tab %>%
                    dplyr::filter(denominazione_regione == region) %>%
                    dplyr::select(-denominazione_regione)
            }
        },

        #' @description
        #' The list of all available regions.
        regions = function() {
            lst_regions <-
                self$get() %>%
                dplyr::distinct(denominazione_regione) %>%
                dplyr::pull()
            names(lst_regions) <- lst_regions
            lst_regions
        },

        #' @description
        #' The list of dates available to fit a regression model.
        dates = function() {
            self$get('ITA') %>%
                dplyr::filter(data > '2020-03-01') %>%
                dplyr::distinct(data) %>%
                dplyr::pull()
        },

        #' @description
        #' This updates the inner table downloading data from the remote repo.
        update = function() {
            private$tab <-
                private$repo %>%
                readr::read_csv(col_types = 'T-cc--iiiiiiiii--ii--') %>%
                # readr::read_csv(col_types = readr::cols()) %>%
                dplyr::mutate(
                    data = lubridate::as_date(data),
                    data = dplyr::case_when(
                        data > Sys.Date() ~ Sys.Date(),
                        TRUE ~ data
                    ),
                    denominazione_regione =
                        dplyr::case_when(
                            codice_regione == '21' ~ 'Trentino-Alto Adige',
                            codice_regione == '22' ~ 'Trentino-Alto Adige',
                            codice_regione == '06' ~ 'Friuli-Venezia Giulia',
                            codice_regione == '08' ~ 'Emilia-Romagna',
                            TRUE ~ denominazione_regione
                        )
                ) %>%
                dplyr::select(-codice_regione) %>%
                dplyr::group_by(data, denominazione_regione) %>%
                dplyr::summarise_all(sum) %>%
                dplyr::ungroup()
            invisible(self)
        },

        #' @description
        #' This function implements a forecast based on a time-dependent SIR
        #' model.
        sir = function(
            region = 'ITA',
            fit_date = max(self$dates()),
            end_date = as.Date('2020-12-31')
        ) {
            start_date <-
                ifelse(
                    fit_date <= as.Date('2020-07-31'),
                    min(self$dates()),
                    '2020-07-31'
                ) %>%
                as.Date(origin = '1970-01-01')
            tbl_data <-
                Covid$new()$get(region) %>%
                dplyr::select(
                    data,
                    X = totale_positivi,
                    R = dimessi_guariti,
                    D = deceduti
                ) %>%
                dplyr::filter(dplyr::between(data, start_date, fit_date))
            if (fit_date > as.Date('2020-07-31')) {
                first_row <-
                    tbl_data %>%
                    head(1) %>%
                    dplyr::select(X0 = X, R0 = R, D0 = D)
                tbl_data %<>%
                    dplyr::bind_cols(first_row) %>%
                    dplyr::mutate(
                        X = X - X0,
                        R = R - R0,
                        D = D - D0
                    ) %>%
                    dplyr::select(-X0, -R0, -D0) %>%
                    tail(-1)
            }
            tbl_data %<>%
                dplyr::bind_rows(
                    dplyr::tibble(
                        data = seq(fit_date + 1, end_date, by = '1 day'),
                        X = NA_real_,
                        R = NA_real_,
                        D = NA_real_
                    )
                )
            idx <- which(is.na(tbl_data$X))
            for (i in idx) {
                # Update fields
                tbl_data %<>%
                    dplyr::mutate(
                        X_1 = lead(X),
                        R_1 = lead(R),
                        D_1 = lead(D),
                        beta = ((X_1 - X) + (R_1 - R) + (D_1 - D)) / X,
                        gamma = ((R_1 - R) + (D_1 - D)) / X,
                        rho = (D_1 - D) / ((R_1 - R) + (D_1 - D))
                    )
                # Exponential regression
                for (field in c('beta', 'gamma', 'rho')) {
                    fit <- lm(
                        formula = log(get(field) + 1e-6) ~ data,
                        data = tidyr::drop_na(tbl_data) %>% tail(50)
                    )
                    tbl_data[i - 1, field] <-
                        exp(predict(fit, tbl_data$data[i - 1])) - 1e-6
                }
                # The mortality rate cannot be negative
                if (round(tbl_data[i - 1, 'rho'], 3) <= 0) {
                    tbl_data[i - 1, 'rho'] <-
                        tbl_data[(i - 6):(i - 2), 'rho'] %>%
                        pull(rho) %>%
                        mean()
                }
                # The mean of the last values is the proxy for the recovery rate
                # tbl_data[i - 1, 'gamma'] <-
                #     tbl_data %>%
                #     dplyr::slice((i - 6):(i - 2)) %>%
                #     dplyr::pull(gamma) %>%
                #     mean()
                # Decreasing step function for the mortality rate
                # fix_rate <- ifelse(
                #     i < 50,
                #     tbl_data[(i - 5):(i - 2), 'rho'] %>% dplyr::pull() %>% mean(),
                #     ifelse(i < 70, 0.20, 0.10)
                # )
                # tbl_data[i - 1, 'rho'] <- fix_rate
                # Compute new fields
                tbl_data$X[i] <-
                    as.integer((1 + tbl_data$beta[i - 1] - tbl_data$gamma[i - 1]) * tbl_data$X[i - 1])
                tbl_data$R[i] <-
                    as.integer(tbl_data$R[i - 1] + tbl_data$gamma[i - 1] * (1 - tbl_data$rho[i - 1]) * tbl_data$X[i - 1])
                tbl_data$D[i] <-
                    as.integer(tbl_data$D[i - 1] + tbl_data$gamma[i - 1] * tbl_data$rho[i - 1] * tbl_data$X[i - 1])
            }
            tbl_data %>%
                dplyr::bind_cols(first_row) %>%
                dplyr::mutate(
                    X = X + X0,
                    R = R + R0,
                    D = D + D0
                ) %>%
                dplyr::select(-X0, -R0, -D0) %>%
                dplyr::mutate(
                    R0 = beta / gamma,
                    total = X + R + D,
                    increment = c(0, diff(total))
                )
        },

        #' @description
        #' This is used to export a plottable table
        table = function(region = 'ITA') {
            self$get(region) %>%
                dplyr::mutate(
                    data = format(data, '%d/%m/%Y')
                ) %>%
                dplyr::mutate_if(is.double, as.integer) %>%
                dplyr::mutate_if(is.integer, function(x) format(x, big.mark = '.', decimal.mark = ',')) %>%
                set_colnames(simple_cap(gsub('_', ' ', names(.))))
        },

        #' @description
        #' This plots a barchart of the summary.
        #' @param delta is a boolean; if \code{TRUE}, the difference from the
        #' previous day is shown.
        plot_hist = function(region = 'ITA', log = FALSE, delta = FALSE) {
            tbl_hist <- self$get(region)
            if (delta) {
                tbl_hist %<>%
                    head(1) %>%
                    dplyr::bind_rows(
                        tbl_hist %>%
                            dplyr::mutate_at(
                                vars(-data),
                                function(x) x - lag(x)
                            ) %>%
                            tidyr::drop_na()
                    )
            }
            tbl_hist %<>% dplyr::mutate(data = datetime_to_timestamp(data))
            hc <-
                highchart() %>%
                hc_chart(type = 'areaspline', zoomType = 'x') %>%
                hc_plotOptions(areaspline = list(stacking = 'normal')) %>%
                hc_subtitle(text = 'Click and drag in the plot area to zoom in') %>%
                hc_xAxis(type = 'datetime') %>%
                hc_tooltip(
                    footerFormat = '<b>  Total: {point.total:,0f}</b>',
                    shared = TRUE
                )
            if (log) {
                hc %<>%
                    hc_yAxis(
                        type = 'logarithmic'
                    )
            }
            hc %<>%
                # Deceduti
                hc_add_series(
                    data = tbl_hist %>%
                        dplyr::select(data, deceduti) %>%
                        list_parse2(),
                    name = 'Deaths'
                ) %>%
                # Dimessi guariti
                hc_add_series(
                    data = tbl_hist %>%
                        dplyr::select(data, dimessi_guariti) %>%
                        list_parse2(),
                    name = 'Recovered'
                ) %>%
                # Terapia intensiva
                hc_add_series(
                    data = tbl_hist %>%
                        dplyr::select(data, terapia_intensiva) %>%
                        list_parse2(),
                    name = 'Intensive Care'
                ) %>%
                # Ricoverati con sintomi
                hc_add_series(
                    data = tbl_hist %>%
                        dplyr::select(data, ricoverati_con_sintomi) %>%
                        list_parse2(),
                    name = 'Hospitalized (no IC)'
                ) %>%
                # Isolamento domiciliare
                hc_add_series(
                    data = tbl_hist %>%
                        dplyr::select(data, isolamento_domiciliare) %>%
                        list_parse2(),
                    name = 'Home Isolation'
                )
            hc
        },

        #' @description
        #' This plots a linechart of the forecast.
        plot_sir = function(
            region = 'ITA',
            fit_date = max(self$dates()),
            end_date = as.Date('2020-12-31')
        ) {
            hc <-
                highchart() %>%
                hc_chart(zoomType = 'x') %>%
                hc_subtitle(text = 'Click and drag in the plot area to zoom in') %>%
                hc_xAxis(
                    type = 'datetime',
                    plotBands = list(
                        from = datetime_to_timestamp(as.Date('2020-02-24')),
                        to = datetime_to_timestamp(fit_date),
                        color = 'rgba(68, 170, 213, .1)'
                    )
                )
            tbl_forecast <-
                try(
                    self$sir(region, fit_date, end_date) %>%
                        dplyr::mutate(data = datetime_to_timestamp(data)),
                    silent = TRUE
                )
            if (class(tbl_forecast)[1] != 'try-error') {
                hc %<>%
                    hc_add_series(
                        data = tbl_forecast %>%
                            dplyr::select(data, X) %>%
                            list_parse2(),
                        name = 'Active Cases',
                        marker = list(
                            fillColor = 'white',
                            lineWidth = 1,
                            lineColor = JS("Highcharts.getOptions().colors[0]")
                        )
                    ) %>%
                    hc_add_series(
                        data = tbl_forecast %>%
                            dplyr::select(data, total) %>%
                            list_parse2(),
                        name = 'Total Cases',
                        marker = list(
                            fillColor = 'white',
                            lineWidth = 1,
                            lineColor = JS("Highcharts.getOptions().colors[1]")
                        )
                    ) %>%
                    hc_add_series(
                        data = tbl_forecast %>%
                            dplyr::select(data, R) %>%
                            list_parse2(),
                        name = 'Recovered',
                        marker = list(
                            fillColor = 'white',
                            lineWidth = 1,
                            lineColor = JS("Highcharts.getOptions().colors[2]")
                        )
                    ) %>%
                    hc_add_series(
                        data = tbl_forecast %>%
                            dplyr::select(data, D) %>%
                            list_parse2(),
                        name = 'Deaths',
                        marker = list(
                            fillColor = 'white',
                            lineWidth = 1,
                            lineColor = JS("Highcharts.getOptions().colors[3]")
                        )
                    )
                hc
            } else {
                return()
            }
        },

        #' @description
        #' This plots a linechart of the model parameters.
            plot_param = function(
            region = 'ITA',
            fit_date = max(self$dates())
        ) {
            hc <-
                highchart() %>%
                hc_chart(type = 'spline', zoomType = 'x') %>%
                hc_subtitle(text = 'Click and drag in the plot area to zoom in') %>%
                hc_xAxis(type = 'datetime') %>%
                hc_yAxis_multiples(
                    list(
                        title = list(text = 'Rates (%)')
                    ),
                    list(
                        title = list(
                            text = 'R0',
                            style = list(color = JS("Highcharts.getOptions().colors[0]"))
                        ),
                        labels = list(
                            style = list(color = JS("Highcharts.getOptions().colors[0]"))
                        ),
                        opposite = TRUE
                    )
                )
            tbl_forecast <-
                try(
                    self$sir(region, fit_date, fit_date + 1) %>%
                        dplyr::mutate_at(vars(beta, gamma, rho, R0), round, digits = 3) %>%
                        dplyr::mutate(data = datetime_to_timestamp(data)),
                    silent = TRUE
                )
            if (class(tbl_forecast)[1] != 'try-error') {
                hc %<>%
                    hc_add_series(
                        data = tbl_forecast %>%
                            dplyr::select(data, R0) %>%
                            list_parse2(),
                        name = 'Reproduction number',
                        color = JS("Highcharts.getOptions().colors[0]"),
                        yAxis = 1,
                        marker = list(
                            fillColor = 'white',
                            symbol = 'circle',
                            radius = 3,
                            lineWidth = 1,
                            lineColor = JS("Highcharts.getOptions().colors[0]")
                        )
                    ) %>%
                    hc_add_series(
                        data = tbl_forecast %>%
                            dplyr::mutate(beta = round(100 * beta, 1)) %>%
                            dplyr::select(data, beta) %>%
                            list_parse2(),
                        name = 'Infection rate',
                        color = JS("Highcharts.getOptions().colors[3]"),
                        tooltip = list(valueSuffix = '%'),
                        marker = list(
                            fillColor = 'white',
                            symbol = 'circle',
                            radius = 3,
                            lineWidth = 1,
                            lineColor = JS("Highcharts.getOptions().colors[3]")
                        )
                    ) %>%
                    hc_add_series(
                        data = tbl_forecast %>%
                            dplyr::mutate(gamma = round(100 * gamma, 1)) %>%
                            dplyr::select(data, gamma) %>%
                            list_parse2(),
                        name = 'Recovery rate',
                        color = JS("Highcharts.getOptions().colors[2]"),
                        tooltip = list(valueSuffix = '%'),
                        marker = list(
                            fillColor = 'white',
                            symbol = 'circle',
                            radius = 3,
                            lineWidth = 1,
                            lineColor = JS("Highcharts.getOptions().colors[2]")
                        )
                    ) %>%
                    hc_add_series(
                        data = tbl_forecast %>%
                            dplyr::mutate(rho = round(100 * rho, 1)) %>%
                            dplyr::select(data, rho) %>%
                            list_parse2(),
                        name = 'Mortality Rate',
                        color = JS("Highcharts.getOptions().colors[1]"),
                        tooltip = list(valueSuffix = '%'),
                        marker = list(
                            fillColor = 'white',
                            symbol = 'circle',
                            radius = 3,
                            lineWidth = 1,
                            lineColor = JS("Highcharts.getOptions().colors[1]")
                        )
                    )
                hc
            } else {
                return()
            }
        }

    ),

    # * Private Members ----
    private = list(

        tab = NULL,
        repo = 'https://raw.githubusercontent.com/pcm-dpc/COVID-19/master/dati-regioni/dpc-covid19-ita-regioni.csv'

    )

)
