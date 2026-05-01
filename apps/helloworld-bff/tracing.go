// OpenTelemetry tracing — Phase 7.6.
//
// Sends OTLP/gRPC spans to the in-cluster collector
// (otel-collector.observability.svc:4317) when OTEL_EXPORTER_OTLP_ENDPOINT
// is set. No-op when unset (so unit tests and dev runs don't require a
// collector). The OTel SDK reads the endpoint env var directly via
// otlptracegrpc.WithInsecure default lookup.

package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

// initTracer wires the OTLP exporter and registers a global TracerProvider.
// Returns a shutdown func that flushes spans (call with a deadline).
// When OTEL_EXPORTER_OTLP_ENDPOINT is empty the returned shutdown is a no-op.
func initTracer(ctx context.Context) (func(context.Context) error, error) {
	endpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	if endpoint == "" {
		slog.Info("tracer disabled (OTEL_EXPORTER_OTLP_ENDPOINT empty)")
		return func(context.Context) error { return nil }, nil
	}
	slog.Info("tracer init", "endpoint", endpoint)

	exp, err := otlptracegrpc.New(ctx, otlptracegrpc.WithInsecure())
	if err != nil {
		return nil, fmt.Errorf("otlp exporter: %w", err)
	}

	res, err := resource.New(ctx,
		resource.WithAttributes(semconv.ServiceName("helloworld-bff")),
		resource.WithFromEnv(),
		resource.WithProcess(),
	)
	if err != nil {
		return nil, fmt.Errorf("otel resource: %w", err)
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exp),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, propagation.Baggage{},
	))
	otel.SetErrorHandler(otel.ErrorHandlerFunc(func(err error) {
		slog.Warn("otel", "err", err)
	}))
	slog.Info("tracer ready", "service", "helloworld-bff")
	return tp.Shutdown, nil
}
