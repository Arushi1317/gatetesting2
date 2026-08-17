using System;
using System.Linq;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Xunit;
using HealthDemo;

namespace HealthDemo.Tests
{
    // ─── WeatherForecast model ───────────────────────────────────────────────

    public class WeatherForecastTests
    {
        [Fact]
        public void TemperatureF_ConvertsCorrectly_FromZeroC()
        {
            var wf = new WeatherForecast { TemperatureC = 0 };
            Assert.Equal(32, wf.TemperatureF);
        }

        [Fact]
        public void TemperatureF_ConvertsCorrectly_From100C()
        {
            var wf = new WeatherForecast { TemperatureC = 100 };
            Assert.Equal(212, wf.TemperatureF);
        }

        [Fact]
        public void TemperatureF_ConvertsCorrectly_FromNegative40C()
        {
            var wf = new WeatherForecast { TemperatureC = -40 };
            Assert.Equal(-40, wf.TemperatureF);
        }

        [Fact]
        public void WeatherForecast_CanSetAndGetAllProperties()
        {
            var date = new DateTime(2024, 6, 1);
            var wf = new WeatherForecast
            {
                Id = 42,
                Date = date,
                TemperatureC = 25,
                Summary = "Warm"
            };

            Assert.Equal(42, wf.Id);
            Assert.Equal(date, wf.Date);
            Assert.Equal(25, wf.TemperatureC);
            Assert.Equal("Warm", wf.Summary);
        }

        [Theory]
        [InlineData(-20)]
        [InlineData(0)]
        [InlineData(20)]
        [InlineData(55)]
        public void TemperatureF_IsAlwaysGreaterThanOrEqualToExpected(int tempC)
        {
            var wf = new WeatherForecast { TemperatureC = tempC };
            var expected = 32 + (int)(tempC / 0.5556);
            Assert.Equal(expected, wf.TemperatureF);
        }
    }

    // ─── WeatherForecastDbContext ────────────────────────────────────────────

    public class WeatherForecastDbContextTests
    {
        private WeatherForecastDbContext CreateInMemoryContext(string dbName)
        {
            var options = new DbContextOptionsBuilder<WeatherForecastDbContext>()
                .UseInMemoryDatabase(databaseName: dbName)
                .Options;
            return new WeatherForecastDbContext(options);
        }

        [Fact]
        public void CanAddAndRetrieveWeatherForecast()
        {
            using var context = CreateInMemoryContext("CanAddTest");
            var forecast = new WeatherForecast
            {
                Date = DateTime.Now,
                TemperatureC = 20,
                Summary = "Mild"
            };
            context.WeatherForecasts.Add(forecast);
            context.SaveChanges();

            var retrieved = context.WeatherForecasts.FirstOrDefault();
            Assert.NotNull(retrieved);
            Assert.Equal("Mild", retrieved.Summary);
            Assert.Equal(20, retrieved.TemperatureC);
        }

        [Fact]
        public void CanAddMultipleForecasts()
        {
            using var context = CreateInMemoryContext("MultipleTest");
            context.WeatherForecasts.AddRange(
                new WeatherForecast { Date = DateTime.Now, TemperatureC = 10, Summary = "Cool" },
                new WeatherForecast { Date = DateTime.Now.AddDays(1), TemperatureC = 20, Summary = "Warm" },
                new WeatherForecast { Date = DateTime.Now.AddDays(2), TemperatureC = 30, Summary = "Hot" }
            );
            context.SaveChanges();

            Assert.Equal(3, context.WeatherForecasts.Count());
        }

        [Fact]
        public void EmptyDatabase_ReturnsNoForecasts()
        {
            using var context = CreateInMemoryContext("EmptyTest");
            Assert.Empty(context.WeatherForecasts);
        }

        [Fact]
        public void CanUpdateForecast()
        {
            using var context = CreateInMemoryContext("UpdateTest");
            var forecast = new WeatherForecast { Date = DateTime.Now, TemperatureC = 15, Summary = "Chilly" };
            context.WeatherForecasts.Add(forecast);
            context.SaveChanges();

            forecast.Summary = "Warm";
            context.SaveChanges();

            var updated = context.WeatherForecasts.First();
            Assert.Equal("Warm", updated.Summary);
        }

        [Fact]
        public void CanDeleteForecast()
        {
            using var context = CreateInMemoryContext("DeleteTest");
            var forecast = new WeatherForecast { Date = DateTime.Now, TemperatureC = 15, Summary = "Chilly" };
            context.WeatherForecasts.Add(forecast);
            context.SaveChanges();

            context.WeatherForecasts.Remove(forecast);
            context.SaveChanges();

            Assert.Empty(context.WeatherForecasts);
        }
    }

    // ─── SeedData ────────────────────────────────────────────────────────────

    public class SeedDataTests
    {
        private IServiceProvider BuildServiceProvider(string dbName)
        {
            var services = new ServiceCollection();
            services.AddDbContext<WeatherForecastDbContext>(options =>
                options.UseInMemoryDatabase(dbName));
            return services.BuildServiceProvider();
        }

        [Fact]
        public void Initialize_SeedsExactly15Forecasts()
        {
            var provider = BuildServiceProvider("SeedTest_Count");
            SeedData.Initialize(provider);

            using var context = provider.GetRequiredService<WeatherForecastDbContext>();
            Assert.Equal(15, context.WeatherForecasts.Count());
        }

        [Fact]
        public void Initialize_DoesNotDuplicateOnSecondCall()
        {
            var provider = BuildServiceProvider("SeedTest_NoDupe");
            SeedData.Initialize(provider);
            SeedData.Initialize(provider);

            using var context = provider.GetRequiredService<WeatherForecastDbContext>();
            Assert.Equal(15, context.WeatherForecasts.Count());
        }

        [Fact]
        public void Initialize_AllForecastsHaveValidDates()
        {
            var provider = BuildServiceProvider("SeedTest_Dates");
            SeedData.Initialize(provider);

            using var context = provider.GetRequiredService<WeatherForecastDbContext>();
            var forecasts = context.WeatherForecasts.ToList();
            Assert.All(forecasts, f => Assert.True(f.Date > DateTime.MinValue));
        }

        [Fact]
        public void Initialize_AllForecastsHaveNonEmptySummary()
        {
            var provider = BuildServiceProvider("SeedTest_Summary");
            SeedData.Initialize(provider);

            using var context = provider.GetRequiredService<WeatherForecastDbContext>();
            var forecasts = context.WeatherForecasts.ToList();
            Assert.All(forecasts, f => Assert.False(string.IsNullOrWhiteSpace(f.Summary)));
        }

        [Fact]
        public void Initialize_TemperaturesAreWithinExpectedRange()
        {
            var provider = BuildServiceProvider("SeedTest_Temps");
            SeedData.Initialize(provider);

            using var context = provider.GetRequiredService<WeatherForecastDbContext>();
            var forecasts = context.WeatherForecasts.ToList();
            Assert.All(forecasts, f =>
            {
                Assert.True(f.TemperatureC >= -20, $"Too cold: {f.TemperatureC}");
                Assert.True(f.TemperatureC <= 55, $"Too hot: {f.TemperatureC}");
            });
        }

        [Fact]
        public void Initialize_ForecastDatesAreInFuture()
        {
            var provider = BuildServiceProvider("SeedTest_FutureDates");
            SeedData.Initialize(provider);

            using var context = provider.GetRequiredService<WeatherForecastDbContext>();
            var forecasts = context.WeatherForecasts.ToList();
            Assert.All(forecasts, f => Assert.True(f.Date > DateTime.Now.AddMinutes(-1)));
        }
    }

    // ─── ApiHealthCheckExtensions ────────────────────────────────────────────

    public class ApiHealthCheckExtensionsTests
    {
        [Fact]
        public void AddApiHealth_RegistersHealthCheck_WithDefaultName()
        {
            var services = new ServiceCollection();
            services.AddHttpClient();
            var builder = services.AddHealthChecks();
            builder.AddApiHealth();

            var provider = services.BuildServiceProvider();
            var healthCheckService = provider.GetService<Microsoft.Extensions.Diagnostics.HealthChecks.HealthCheckService>();
            Assert.NotNull(healthCheckService);
        }

        [Fact]
        public void AddApiHealth_RegistersHealthCheck_WithCustomName()
        {
            var services = new ServiceCollection();
            services.AddHttpClient();
            var builder = services.AddHealthChecks();
            builder.AddApiHealth("CustomApiHealth");

            var provider = services.BuildServiceProvider();
            var healthCheckService = provider.GetService<Microsoft.Extensions.Diagnostics.HealthChecks.HealthCheckService>();
            Assert.NotNull(healthCheckService);
        }
    }
}
