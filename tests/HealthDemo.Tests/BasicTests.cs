using Xunit;

public class BasicTests
{
    [Fact]
    public void OnePlusOneEqualsTwo()
    {
        Assert.Equal(2, 1 + 1);
    }

    [Fact]
    public void StringIsNotEmpty()
    {
        Assert.NotEmpty("HealthDemo");
    }
}
