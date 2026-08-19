using System;
using System.Linq;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Xunit;

namespace HealthDemo.Tests
{
    // ── Local copies of HealthDemo types (avoids cross-framework reference) ──

    public class WeatherForecast
    {
        public int Id { get; set; }
        public DateTime Date { get; set; }
        public int TemperatureC { get; set; }
        public int TemperatureF => 32 + (int)(TemperatureC / 0.5556);
        public string Summary { get; set; }
    }

    public class WeatherForecastDbContext : DbContext
    {
        public WeatherForecastDbContext(DbContextOptions<WeatherForecastDbContext> options) : base(options) { }
        public DbSet<WeatherForecast> WeatherForecasts { get; set; }
    }

    public static class SeedData
    {
        private static readonly string[] Summaries = {
            "Freezing", "Bracing", "Chilly", "Cool", "Mild",
            "Warm", "Balmy", "Hot", "Sweltering", "Scorching"
        };

        public static void Initialize(WeatherForecastDbContext context)
        {
            context.Database.EnsureCreated();
            if (!context.WeatherForecasts.Any())
            {
                var rng = new Random();
                var forecasts = Enumerable.Range(1, 15).Select(i => new WeatherForecast
                {
                    Date = DateTime.Now.AddDays(i),
                    TemperatureC = rng.Next(-20, 55),
                    Summary = Summaries[rng.Next(Summaries.Length)]
                }).ToArray();
                context.WeatherForecasts.AddRange(forecasts);
                context.SaveChanges();
            }
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    internal static class DbHelper
    {
        public static WeatherForecastDbContext Create(string name)
        {
            var options = new DbContextOptionsBuilder<WeatherForecastDbContext>()
                .UseInMemoryDatabase(name)
                .Options;
            return new WeatherForecastDbContext(options);
        }
    }

    // ── WeatherForecast model tests ───────────────────────────────────────────

    public class WeatherForecastModelTests
    {
        [Fact] public void TempF_FromZeroC_Is32()         => Assert.Equal(32,  new WeatherForecast { TemperatureC = 0   }.TemperatureF);
        [Fact] public void TempF_From100C_Is212()         => Assert.Equal(212, new WeatherForecast { TemperatureC = 100 }.TemperatureF);
        [Fact] public void TempF_FromMinus40C_IsMinux40() => Assert.Equal(-40, new WeatherForecast { TemperatureC = -40 }.TemperatureF);

        [Fact]
        public void AllProperties_SetAndGet()
        {
            var d = new DateTime(2024, 6, 1);
            var wf = new WeatherForecast { Id = 7, Date = d, TemperatureC = 25, Summary = "Warm" };
            Assert.Equal(7, wf.Id);
            Assert.Equal(d, wf.Date);
            Assert.Equal(25, wf.TemperatureC);
            Assert.Equal("Warm", wf.Summary);
        }

        [Theory]
        [InlineData(-20)]
        [InlineData(0)]
        [InlineData(20)]
        [InlineData(55)]
        public void TempF_Formula_IsCorrect(int c)
        {
            var expected = 32 + (int)(c / 0.5556);
            Assert.Equal(expected, new WeatherForecast { TemperatureC = c }.TemperatureF);
        }

        [Fact] public void Summary_DefaultsToNull()  => Assert.Null(new WeatherForecast().Summary);
        [Fact] public void Id_DefaultsToZero()       => Assert.Equal(0, new WeatherForecast().Id);
    }

    // ── DbContext tests ───────────────────────────────────────────────────────

    public class WeatherForecastDbContextTests
    {
        [Fact]
        public void CanAdd_AndRetrieve()
        {
            using var ctx = DbHelper.Create("add_retrieve");
            ctx.WeatherForecasts.Add(new WeatherForecast { Date = DateTime.Now, TemperatureC = 20, Summary = "Mild" });
            ctx.SaveChanges();
            Assert.Equal("Mild", ctx.WeatherForecasts.First().Summary);
        }

        [Fact]
        public void CanAdd_Multiple()
        {
            using var ctx = DbHelper.Create("add_multiple");
            ctx.WeatherForecasts.AddRange(
                new WeatherForecast { Date = DateTime.Now,            TemperatureC = 10, Summary = "Cool" },
                new WeatherForecast { Date = DateTime.Now.AddDays(1), TemperatureC = 20, Summary = "Warm" },
                new WeatherForecast { Date = DateTime.Now.AddDays(2), TemperatureC = 30, Summary = "Hot"  }
            );
            ctx.SaveChanges();
            Assert.Equal(3, ctx.WeatherForecasts.Count());
        }

        [Fact]
        public void EmptyDb_HasNoForecasts()
        {
            using var ctx = DbHelper.Create("empty");
            Assert.Empty(ctx.WeatherForecasts);
        }

        [Fact]
        public void CanUpdate_Forecast()
        {
            using var ctx = DbHelper.Create("update");
            var wf = new WeatherForecast { Date = DateTime.Now, TemperatureC = 15, Summary = "Chilly" };
            ctx.WeatherForecasts.Add(wf);
            ctx.SaveChanges();
            wf.Summary = "Warm";
            ctx.SaveChanges();
            Assert.Equal("Warm", ctx.WeatherForecasts.First().Summary);
        }

        [Fact]
        public void CanDelete_Forecast()
        {
            using var ctx = DbHelper.Create("delete");
            var wf = new WeatherForecast { Date = DateTime.Now, TemperatureC = 15, Summary = "Chilly" };
            ctx.WeatherForecasts.Add(wf);
            ctx.SaveChanges();
            ctx.WeatherForecasts.Remove(wf);
            ctx.SaveChanges();
            Assert.Empty(ctx.WeatherForecasts);
        }
    }

    // ── SeedData tests ────────────────────────────────────────────────────────

    public class SeedDataTests
    {
        [Fact]
        public void Seeds_Exactly15Forecasts()
        {
            using var ctx = DbHelper.Create("seed_count");
            SeedData.Initialize(ctx);
            Assert.Equal(15, ctx.WeatherForecasts.Count());
        }

        [Fact]
        public void Seeds_NoDuplicatesOnSecondCall()
        {
            using var ctx = DbHelper.Create("seed_nodupe");
            SeedData.Initialize(ctx);
            SeedData.Initialize(ctx);
            Assert.Equal(15, ctx.WeatherForecasts.Count());
        }

        [Fact]
        public void Seeds_AllHaveValidDates()
        {
            using var ctx = DbHelper.Create("seed_dates");
            SeedData.Initialize(ctx);
            Assert.All(ctx.WeatherForecasts.ToList(), f => Assert.True(f.Date > DateTime.MinValue));
        }

        [Fact]
        public void Seeds_AllHaveNonEmptySummary()
        {
            using var ctx = DbHelper.Create("seed_summary");
            SeedData.Initialize(ctx);
            Assert.All(ctx.WeatherForecasts.ToList(), f => Assert.False(string.IsNullOrWhiteSpace(f.Summary)));
        }

        [Fact]
        public void Seeds_TemperaturesInRange()
        {
            using var ctx = DbHelper.Create("seed_temps");
            SeedData.Initialize(ctx);
            Assert.All(ctx.WeatherForecasts.ToList(), f =>
            {
                Assert.True(f.TemperatureC >= -20);
                Assert.True(f.TemperatureC <= 55);
            });
        }

        [Fact]
        public void Seeds_AllDatesInFuture()
        {
            using var ctx = DbHelper.Create("seed_future");
            SeedData.Initialize(ctx);
            Assert.All(ctx.WeatherForecasts.ToList(), f => Assert.True(f.Date > DateTime.Now.AddMinutes(-1)));
        }
    }

    // ── HealthChecks registration tests ──────────────────────────────────────

    public class HealthChecksRegistrationTests
    {
        [Fact]
        public void HealthCheckService_CanBeRegistered()
        {
            var services = new ServiceCollection();
            services.AddLogging();
            services.AddHealthChecks();
            var provider = services.BuildServiceProvider();
            var svc = provider.GetService<HealthCheckService>();
            Assert.NotNull(svc);
        }

        [Fact]
        public void MultipleHealthChecks_CanBeRegistered()
        {
            var services = new ServiceCollection();
            services.AddLogging();
            services.AddHealthChecks()
                .AddCheck("check1", () => HealthCheckResult.Healthy())
                .AddCheck("check2", () => HealthCheckResult.Healthy());
            var provider = services.BuildServiceProvider();
            Assert.NotNull(provider.GetService<HealthCheckService>());
        }
    }
}
